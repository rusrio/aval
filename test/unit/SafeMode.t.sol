// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";

/// @notice Safe mode: a slash that leaves the bond below MIN_BOND disables the operator, blocks deposits and moves
///         the vault to a full-range position. Topping the bond back up exits safe mode.
contract SafeModeTest is AvalFixture {
    event SafeModeEntered(uint256 indexed vaultId, uint256 bond);
    event SafeModeExited(uint256 indexed vaultId);

    address internal carol = makeAddr("carol");

    uint256 internal honest;
    uint256 internal weak;

    function setUp() public override {
        super.setUp();
        _fund(carol);
        honest = createDefaultVault();
        // Barely above MIN_BOND; mostly USDC and never deployed, so an ETH rally slashes it below the minimum.
        uint256 weakBond = hook.MIN_BOND() + 30e6;
        vm.prank(owner);
        weak = hook.createVault(key, defaultPolicy(), operator, weakBond, initSqrtPrice);
        depositAs(alice, honest, 300_000e6, 100 ether);
        depositAs(bob, weak, 9_000e6, 0.3 ether);
        warpAndRoll(defaultPolicy().epochLength);
        hook.settleEpoch(honest);
        hook.settleEpoch(weak);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 6000);
        vm.prank(operator);
        hook.rebalance(honest, lower, upper);
    }

    /// @dev ETH rally, then the epoch (and TWAP window) passes.
    function _rally() internal {
        swap(usdcIs0, 30_000e6);
        warpAndRoll(defaultPolicy().epochLength);
    }

    function _enterSafeMode() internal {
        _rally();
        hook.settleEpoch(weak);
        assertTrue(hook.getVault(weak).safeMode, "precondition: safe mode");
    }

    // ------------------------------------------------------------------
    // Entering
    // ------------------------------------------------------------------

    function test_safeMode_enteredWhenSlashDropsBondBelowMin() public {
        _rally();
        vm.expectEmit(true, false, false, false, address(hook));
        emit SafeModeEntered(weak, 0);
        hook.settleEpoch(weak);

        AvalHook.Vault memory v = hook.getVault(weak);
        assertTrue(v.safeMode);
        assertLt(v.bond, hook.MIN_BOND());
    }

    function test_safeMode_movesToFullRange() public {
        _enterSafeMode();
        AvalHook.Vault memory v = hook.getVault(weak);
        assertEq(v.tickLower, TickMath.minUsableTick(60));
        assertEq(v.tickUpper, TickMath.maxUsableTick(60));
        assertGt(v.liquidity, 0);
    }

    function test_safeMode_notEnteredWithHealthyBond() public {
        _rally();
        hook.settleEpoch(honest);
        assertFalse(hook.getVault(honest).safeMode);
    }

    function test_safeMode_skipsRedeployWhenSpotFarFromTwap() public {
        _rally();
        swap(!usdcIs0, 20 ether); // spot dumps in the settlement block, TWAP barely moves
        hook.settleEpoch(weak);
        AvalHook.Vault memory v = hook.getVault(weak);
        assertTrue(v.safeMode, "still enters safe mode");
        assertEq(v.liquidity, 0, "no deployment at a manipulated spot");

        // Once spot and TWAP agree again, the next settlement deploys full range.
        warpAndRoll(defaultPolicy().epochLength);
        hook.settleEpoch(weak);
        assertGt(hook.getVault(weak).liquidity, 0);
    }

    // ------------------------------------------------------------------
    // While in safe mode
    // ------------------------------------------------------------------

    function test_revert_safeMode_operatorDisabled() public {
        _enterSafeMode();
        warpAndRoll(defaultPolicy().cooldown);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 600);
        vm.prank(operator);
        vm.expectRevert(AvalHook.SafeModeActive.selector);
        hook.rebalance(weak, lower, upper);
    }

    function test_revert_safeMode_depositsBlocked() public {
        _enterSafeMode();
        (uint256 a0, uint256 a1) = amounts(100e6, 0);
        vm.prank(carol);
        vm.expectRevert(AvalHook.SafeModeActive.selector);
        hook.deposit(weak, a0, a1);
    }

    function test_safeMode_queuedDepositActivatedAndDeployed() public {
        _rally();
        depositAs(carol, weak, 100e6, 0.01 ether); // queued before the settlement that enters safe mode
        hook.settleEpoch(weak);
        vm.prank(carol);
        hook.claimShares(weak);
        assertGt(hook.sharesOf(weak, carol), 0);
        assertGt(hook.getVault(weak).liquidity, 0);
    }

    function test_safeMode_withdrawStillWorks() public {
        _enterSafeMode();
        vm.startPrank(bob);
        hook.claimShares(weak);
        hook.withdraw(weak, hook.sharesOf(weak, bob), 0, 0);
        vm.stopPrank();
        AvalHook.Vault memory v = hook.getVault(weak);
        assertEq(v.totalShares, 0);
        assertLe(v.liquidity, 1);
    }

    // ------------------------------------------------------------------
    // Exiting
    // ------------------------------------------------------------------

    function test_safeMode_exitWhenBondToppedUp() public {
        _enterSafeMode();
        uint256 missing = hook.MIN_BOND() - hook.getVault(weak).bond;
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(hook));
        emit SafeModeExited(weak);
        hook.addBond(weak, missing);
        assertFalse(hook.getVault(weak).safeMode);

        warpAndRoll(defaultPolicy().cooldown);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 600);
        vm.prank(operator);
        hook.rebalance(weak, lower, upper);
    }

    function test_safeMode_partialTopUpStays() public {
        _enterSafeMode();
        vm.prank(owner);
        hook.addBond(weak, 1);
        assertTrue(hook.getVault(weak).safeMode);
    }
}
