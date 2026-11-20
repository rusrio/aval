// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";
import {PolicyLib} from "../../src/libraries/PolicyLib.sol";
import {TwapLib} from "../../src/libraries/TwapLib.sol";
import {PerformanceLib} from "../../src/libraries/PerformanceLib.sol";

contract AvalHookTest is AvalFixture {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Vault with alice's 30k USDC + 10 WETH activated and deployed around spot.
    function _activeVault() internal returns (uint256 vaultId) {
        vaultId = createDefaultVault();
        depositAs(alice, vaultId, 30_000e6, 10 ether);
        settleAfterEpoch(vaultId);
        vm.prank(alice);
        hook.claimShares(vaultId);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        hook.rebalance(vaultId, lower, upper);
    }

    // ------------------------------------------------------------------
    // Pool & vault creation
    // ------------------------------------------------------------------

    function test_createVault_initializesPoolAndStoresVault() public {
        uint256 id = createDefaultVault();
        assertEq(id, 1);
        (bool initialized, bool bondIsToken0) = hook.pools(poolId);
        assertTrue(initialized);
        assertEq(bondIsToken0, usdcIs0);
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPrice, initSqrtPrice);

        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.owner, owner);
        assertEq(v.operator, operator);
        assertEq(v.epochStart, block.timestamp);
    }

    function test_createVault_secondVaultReusesPool() public {
        createDefaultVault();
        vm.prank(bob);
        uint256 id2 = hook.createVault(key, defaultPolicy(), bob, 0, 1); // price ignored
        assertEq(id2, 2);
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPrice, initSqrtPrice);
    }

    function test_createVault_pullsBond() public {
        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        uint256 id = hook.createVault(key, defaultPolicy(), operator, 1_000e6, initSqrtPrice);
        assertEq(before - usdc.balanceOf(owner), 1_000e6);
        assertEq(hook.getVault(id).bond, 1_000e6);
    }

    function test_revert_createVault_staticFee() public {
        PoolKey memory k = key;
        k.fee = 3000;
        vm.expectRevert(AvalHook.InvalidPoolKey.selector);
        hook.createVault(k, defaultPolicy(), operator, 0, initSqrtPrice);
    }

    function test_revert_createVault_wrongTickSpacing() public {
        PoolKey memory k = key;
        k.tickSpacing = 10;
        vm.expectRevert(AvalHook.InvalidPoolKey.selector);
        hook.createVault(k, defaultPolicy(), operator, 0, initSqrtPrice);
    }

    function test_revert_createVault_tokenNotAllowed() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        (address a, address b) =
            address(other) < address(usdc) ? (address(other), address(usdc)) : (address(usdc), address(other));
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        vm.expectRevert(AvalHook.TokenNotAllowed.selector);
        hook.createVault(k, defaultPolicy(), operator, 0, initSqrtPrice);
    }

    function test_revert_createVault_invalidPolicy() public {
        PolicyLib.Policy memory p = defaultPolicy();
        p.minWidthTicks = 10; // below platform minimum
        vm.expectRevert(PolicyLib.InvalidPolicy.selector);
        hook.createVault(key, p, operator, 0, initSqrtPrice);
    }

    function test_revert_externalInitialize() public {
        vm.expectRevert();
        poolManager.initialize(key, initSqrtPrice);
    }

    function test_revert_externalAddLiquidity() public {
        uint256 id = _activeVault();
        AvalHook.Vault memory v = hook.getVault(id);
        uint128 liqBefore = poolManager.getLiquidity(poolId);

        // A third party (through the PositionManager) cannot add liquidity to an Aval pool.
        vm.startPrank(alice);
        permit2.approve(address(usdc), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(weth), address(positionManager), type(uint160).max, type(uint48).max);
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, v.tickLower, v.tickUpper, uint256(1e12), type(uint128).max, type(uint128).max, alice, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        vm.expectRevert();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
        vm.stopPrank();

        assertEq(poolManager.getLiquidity(poolId), liqBefore);
    }

    function test_setPolicy_onlyBeforeDeposits() public {
        uint256 id = createDefaultVault();
        PolicyLib.Policy memory p = defaultPolicy();
        p.cooldown = 120;
        vm.prank(owner);
        hook.setPolicy(id, p);
        assertEq(hook.getVault(id).policy.cooldown, 120);

        depositAs(alice, id, 1_000e6, 0);
        vm.prank(owner);
        vm.expectRevert(AvalHook.PolicyLocked.selector);
        hook.setPolicy(id, p);
    }

    // ------------------------------------------------------------------
    // Deposits / epochs
    // ------------------------------------------------------------------

    function test_deposit_isQueuedUntilSettle() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 30_000e6, 10 ether);

        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.totalShares, 0);
        assertEq(v.idle0 + v.idle1, 0);
        assertGt(v.pending0 + v.pending1, 0);
        assertEq(hook.sharesOf(id, alice), 0);

        vm.expectRevert(AvalHook.EpochNotOver.selector);
        hook.settleEpoch(id);

        settleAfterEpoch(id);
        v = hook.getVault(id);
        assertEq(v.epoch, 1);
        assertEq(v.pending0 + v.pending1, 0);
        assertGt(v.totalShares, 0);

        vm.prank(alice);
        hook.claimShares(id);
        assertEq(hook.sharesOf(id, alice), v.totalShares, "single depositor owns all minted shares");
        // ~60k USDC of value -> ~60k * 1e6 * VIRTUAL_SHARES shares
        assertApproxEqRel(v.totalShares, 60_000e6 * PerformanceLib.VIRTUAL_SHARES, 0.01e18);
    }

    function test_settle_revertsWhenTwapNotWarm() public {
        PolicyLib.Policy memory p = defaultPolicy();
        p.epochLength = 60; // shorter than TWAP window
        vm.prank(owner);
        uint256 id = hook.createVault(key, p, operator, 0, initSqrtPrice);
        warpAndRoll(60);
        vm.expectRevert(TwapLib.TwapNotWarm.selector);
        hook.settleEpoch(id);
    }

    function test_secondDepositorPaysFairPrice() public {
        uint256 id = _activeVault();
        depositAs(bob, id, 60_000e6, 0); // same value as alice, all USDC
        settleAfterEpoch(id);
        vm.prank(bob);
        hook.claimShares(id);
        assertApproxEqRel(hook.sharesOf(id, bob), hook.sharesOf(id, alice), 0.01e18);
    }

    function test_cancelDeposit_refunds() public {
        uint256 id = createDefaultVault();
        uint256 before = usdc.balanceOf(alice);
        depositAs(alice, id, 5_000e6, 0);
        vm.prank(alice);
        hook.cancelDeposit(id);
        assertEq(usdc.balanceOf(alice), before);
        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.pending0 + v.pending1, 0);
    }

    function test_revert_cancelDeposit_afterActivation() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 5_000e6, 0);
        settleAfterEpoch(id);
        vm.prank(alice);
        vm.expectRevert(AvalHook.NothingPending.selector);
        hook.cancelDeposit(id);
    }

    function test_depositAutoClaimsPreviousEpoch() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 5_000e6, 0);
        settleAfterEpoch(id);
        depositAs(alice, id, 1_000e6, 0); // claims epoch-0 shares first
        assertGt(hook.sharesOf(id, alice), 0);
        (uint64 epoch, uint256 a0, uint256 a1) = hook.pendingDeposits(id, alice);
        assertEq(epoch, 1);
        assertEq(a0 + a1, 1_000e6);
    }

    // ------------------------------------------------------------------
    // Rebalance
    // ------------------------------------------------------------------

    function test_rebalance_deploysLiquidity() public {
        uint256 id = _activeVault();
        AvalHook.Vault memory v = hook.getVault(id);
        assertGt(v.liquidity, 0);
        (uint128 liq,,) = poolManager.getPositionInfo(poolId, address(hook), v.tickLower, v.tickUpper, bytes32(id));
        assertEq(liq, v.liquidity);
        assertEq(poolManager.getLiquidity(poolId), v.liquidity, "only the vault provides liquidity");
        assertEq(v.rebalancesThisEpoch, 1);
    }

    function test_rebalance_preservesValueAtTwap() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 30_000e6, 10 ether);
        settleAfterEpoch(id);
        uint256 before = hook.getVaultValue(id);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);
        // Tokens are deployed at spot but valued at TWAP: only a second-order spot/TWAP divergence remains.
        assertApproxEqRel(hook.getVaultValue(id), before, 1e11, "no value extracted by rebalance");

        warpAndRoll(60);
        (lower, upper) = rangeAround(spotTick() + 300, 600);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);
        assertApproxEqRel(hook.getVaultValue(id), before, 1e11);
    }

    function test_revert_rebalance_onlyOperator() public {
        uint256 id = createDefaultVault();
        warpAndRoll(TWAP_WINDOW);
        vm.prank(alice);
        vm.expectRevert(AvalHook.OnlyOperator.selector);
        hook.rebalance(id, -600, 600);
    }

    function test_revert_rebalance_twapNotWarm() public {
        uint256 id = createDefaultVault();
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        vm.expectRevert(TwapLib.TwapNotWarm.selector);
        hook.rebalance(id, lower, upper);
    }

    function test_revert_rebalance_cooldown() public {
        uint256 id = _activeVault();
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        vm.expectRevert(AvalHook.CooldownActive.selector);
        hook.rebalance(id, lower, upper);
    }

    function test_revert_rebalance_tooManyPerEpoch() public {
        uint256 id = _activeVault();
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        for (uint256 i = 1; i < defaultPolicy().maxRebalancesPerEpoch; ++i) {
            warpAndRoll(60);
            vm.prank(operator);
            hook.rebalance(id, lower, upper);
        }
        warpAndRoll(60);
        vm.prank(operator);
        vm.expectRevert(AvalHook.TooManyRebalances.selector);
        hook.rebalance(id, lower, upper);
    }

    function test_revert_rebalance_misaligned() public {
        uint256 id = createDefaultVault();
        warpAndRoll(TWAP_WINDOW);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        vm.expectRevert(AvalHook.InvalidRange.selector);
        hook.rebalance(id, lower + 1, upper);
    }

    function test_revert_rebalance_width() public {
        uint256 id = createDefaultVault();
        warpAndRoll(TWAP_WINDOW);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 60); // width 120 ok
        vm.prank(operator);
        hook.rebalance(id, lower, upper);

        warpAndRoll(60);
        (lower, upper) = rangeAround(spotTick(), 6060); // width 12120 > 12000
        vm.prank(operator);
        vm.expectRevert(AvalHook.InvalidWidth.selector);
        hook.rebalance(id, lower, upper);
    }

    function test_revert_rebalance_rangeFarFromTwap() public {
        uint256 id = createDefaultVault();
        warpAndRoll(TWAP_WINDOW);
        (int24 lower, int24 upper) = rangeAround(spotTick() + 1200, 600);
        vm.prank(operator);
        vm.expectRevert(AvalHook.RangeTooFarFromTwap.selector);
        hook.rebalance(id, lower, upper);
    }

    function test_revert_rebalance_spotFarFromTwap() public {
        uint256 id = _activeVault();
        warpAndRoll(TWAP_WINDOW);
        int24 tickBefore = spotTick();
        swap(!usdcIs0, 3 ether); // sell WETH: big move in one block
        assertGt(_abs(int256(spotTick()) - int256(tickBefore)), 100, "swap must move spot > limit");
        warpAndRoll(1);
        (int24 lower, int24 upper) = rangeAround(tickBefore, 1200);
        vm.prank(operator);
        vm.expectRevert(AvalHook.SpotTooFarFromTwap.selector);
        hook.rebalance(id, lower, upper);
    }

    // ------------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------------

    function test_withdraw_inKindProRata() public {
        uint256 id = _activeVault();
        uint256 shares = hook.sharesOf(id, alice);
        uint256 u0 = usdc.balanceOf(alice);
        uint256 w0 = weth.balanceOf(alice);

        vm.prank(alice);
        hook.withdraw(id, shares / 2, 0, 0);
        uint256 gotUsdc = usdc.balanceOf(alice) - u0;
        uint256 gotWeth = weth.balanceOf(alice) - w0;
        assertApproxEqRel(gotUsdc, 15_000e6, 0.001e18);
        assertApproxEqRel(gotWeth, 5 ether, 0.001e18);

        vm.prank(alice);
        hook.withdraw(id, shares - shares / 2, 0, 0);
        assertApproxEqAbs(usdc.balanceOf(alice), u0 + 30_000e6, 10);
        assertApproxEqAbs(weth.balanceOf(alice), w0 + 10 ether, 1e9);
        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.totalShares, 0);
        assertEq(v.liquidity, 0);
    }

    function test_withdraw_includesSwapFees() public {
        uint256 id = _activeVault();
        for (uint256 i; i < 10; ++i) {
            swap(true, usdcIs0 ? 3_000e6 : 1 ether);
            swap(false, usdcIs0 ? 1 ether : 3_000e6);
            warpAndRoll(12);
        }
        uint256 shares = hook.sharesOf(id, alice);
        vm.prank(alice);
        (uint256 a0, uint256 a1) = hook.withdraw(id, shares, 0, 0);
        uint256 usdcOut = usdcIs0 ? a0 : a1;
        uint256 wethOut = usdcIs0 ? a1 : a0;
        uint256 value = usdcOut + wethOut * ETH_PRICE_USDC / 1e12;
        assertGt(value, 60_000e6, "LP earns swap fees");
    }

    function test_revert_withdraw_slippage() public {
        uint256 id = _activeVault();
        uint256 shares = hook.sharesOf(id, alice);
        vm.prank(alice);
        vm.expectRevert(AvalHook.Slippage.selector);
        hook.withdraw(id, shares, type(uint256).max, 0);
    }

    function test_revert_withdraw_insufficientShares() public {
        uint256 id = _activeVault();
        vm.prank(bob);
        vm.expectRevert(AvalHook.InsufficientShares.selector);
        hook.withdraw(id, 1, 0, 0);
    }

    function test_withdraw_doesNotTouchOtherVault() public {
        uint256 a = _activeVault();
        vm.prank(bob);
        uint256 b = hook.createVault(key, defaultPolicy(), operator, 0, 0);
        depositAs(bob, b, 10_000e6, 2 ether);
        settleAfterEpoch(b);
        AvalHook.Vault memory before = hook.getVault(b);

        uint256 shares = hook.sharesOf(a, alice);
        vm.prank(alice);
        hook.withdraw(a, shares, 0, 0);

        AvalHook.Vault memory afterB = hook.getVault(b);
        assertEq(afterB.idle0, before.idle0);
        assertEq(afterB.idle1, before.idle1);
        assertEq(afterB.totalShares, before.totalShares);
    }

    // ------------------------------------------------------------------
    // TWAP & dynamic fee
    // ------------------------------------------------------------------

    function test_twap_followsSpotAfterWindow() public {
        _activeVault();
        swap(!usdcIs0, 1 ether); // sell WETH
        int24 newSpot = spotTick();
        warpAndRoll(TWAP_WINDOW * 2);
        assertApproxEqAbs(int256(hook.getTwapTick(poolId)), int256(newSpot), 1);
    }

    function test_twap_lagsImmediatelyAfterMove() public {
        _activeVault();
        warpAndRoll(TWAP_WINDOW);
        int24 before = spotTick();
        swap(!usdcIs0, 3 ether);
        warpAndRoll(1);
        int24 twap = hook.getTwapTick(poolId);
        assertLt(_abs(int256(twap) - int256(before)), _abs(int256(spotTick()) - int256(before)) / 10);
    }

    function test_dynamicFee_risesWithDeviation() public {
        _activeVault();
        warpAndRoll(TWAP_WINDOW);
        assertEq(hook.currentFee(poolId), hook.BASE_FEE());
        swap(!usdcIs0, 3 ether);
        warpAndRoll(1);
        assertGt(hook.currentFee(poolId), hook.BASE_FEE());
        assertLe(hook.currentFee(poolId), hook.MAX_FEE());
    }

    // ------------------------------------------------------------------
    // Gas: swap path is O(1) in the number of vaults (invariant 5)
    // ------------------------------------------------------------------

    function test_swapGas_independentOfVaultCount() public {
        uint256 id = _activeVault();
        AvalHook.Vault memory v = hook.getVault(id);
        warpAndRoll(TWAP_WINDOW);

        uint256 snap = vm.snapshotState();
        uint256 gasOne = _measureSwap();
        vm.revertToState(snap);

        for (uint256 i; i < 9; ++i) {
            vm.prank(bob);
            uint256 vid = hook.createVault(key, defaultPolicy(), operator, 0, 0);
            depositAs(bob, vid, 3_000e6, 1 ether);
        }
        warpAndRoll(defaultPolicy().epochLength);
        for (uint256 vid = 2; vid <= 10; ++vid) {
            hook.settleEpoch(vid);
            vm.prank(operator);
            hook.rebalance(vid, v.tickLower, v.tickUpper); // same ticks -> same tick crossings
        }
        warpAndRoll(TWAP_WINDOW);
        uint256 gasTen = _measureSwap();
        assertApproxEqRel(gasTen, gasOne, 0.05e18, "swap gas must not grow with vaults");
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _measureSwap() internal returns (uint256 used) {
        vm.prank(trader);
        uint256 g = gasleft();
        swapRouter.swapExactTokensForTokens(0.1 ether, 0, !usdcIs0, key, "", trader, block.timestamp + 1);
        used = g - gasleft();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
