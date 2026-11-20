// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BaseTest} from "./BaseTest.sol";
import {AvalHook} from "../../src/AvalHook.sol";
import {PolicyLib} from "../../src/libraries/PolicyLib.sol";

/// @notice Shared setup: v4 artifacts, mWETH/mUSDC, AvalHook at a flagged address, one pool at ~3000 USDC/ETH.
abstract contract AvalFixture is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant TWAP_WINDOW = 300;
    uint256 internal constant ETH_PRICE_USDC = 3000;
    /// @dev Large enough that the TVL cap never binds in non-bond tests (cap = 50M mUSDC).
    uint256 internal constant DEFAULT_BOND = 5_000_000e6;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    AvalHook internal hook;
    PoolKey internal key;
    PoolId internal poolId;
    bool internal usdcIs0;
    uint160 internal initSqrtPrice;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        deployArtifactsAndLabel();

        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        weth = new MockERC20("Mock WETH", "mWETH", 18);
        vm.label(address(usdc), "mUSDC");
        vm.label(address(weth), "mWETH");
        usdcIs0 = address(usdc) < address(weth);

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
            ) ^ (0x4444 << 144)
        );
        address[] memory allowed = new address[](1);
        allowed[0] = address(weth);
        deployCodeTo("AvalHook.sol:AvalHook", abi.encode(poolManager, address(usdc), allowed, TWAP_WINDOW), flags);
        hook = AvalHook(flags);
        vm.label(flags, "AvalHook");

        key = PoolKey({
            currency0: Currency.wrap(usdcIs0 ? address(usdc) : address(weth)),
            currency1: Currency.wrap(usdcIs0 ? address(weth) : address(usdc)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        initSqrtPrice = sqrtPriceForEthPrice(ETH_PRICE_USDC);

        _fund(owner);
        _fund(alice);
        _fund(bob);
        _fund(trader);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev sqrtPriceX96 of token1/token0 in raw units for an ETH price in whole USDC.
    function sqrtPriceForEthPrice(uint256 ethPrice) internal view returns (uint160) {
        // raw price token1 per token0
        uint256 num;
        uint256 den;
        if (usdcIs0) {
            // WETH per USDC: (1/ethPrice) * 1e18 / 1e6
            num = 1e12;
            den = ethPrice;
        } else {
            // USDC per WETH: ethPrice * 1e6 / 1e18
            num = ethPrice;
            den = 1e12;
        }
        return uint160(FixedPointMathLib.sqrt((num << 192) / den));
    }

    function defaultPolicy() internal pure returns (PolicyLib.Policy memory) {
        return PolicyLib.Policy({
            maxRangeDeviationTicks: 600,
            maxSpotTwapDeviationBps: 100,
            cooldown: 60,
            maxRebalancesPerEpoch: 5,
            minWidthTicks: 120,
            maxWidthTicks: 12_000,
            epochLength: 600
        });
    }

    function createDefaultVault() internal returns (uint256 vaultId) {
        vm.prank(owner);
        vaultId = hook.createVault(key, defaultPolicy(), operator, DEFAULT_BOND, initSqrtPrice);
    }

    function amounts(uint256 usdcAmount, uint256 wethAmount) internal view returns (uint256 a0, uint256 a1) {
        (a0, a1) = usdcIs0 ? (usdcAmount, wethAmount) : (wethAmount, usdcAmount);
    }

    function depositAs(address user, uint256 vaultId, uint256 usdcAmount, uint256 wethAmount) internal {
        (uint256 a0, uint256 a1) = amounts(usdcAmount, wethAmount);
        vm.prank(user);
        hook.deposit(vaultId, a0, a1);
    }

    function spotTick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function warpAndRoll(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Advances time and settles so queued deposits become active.
    function settleAfterEpoch(uint256 vaultId) internal {
        warpAndRoll(defaultPolicy().epochLength);
        hook.settleEpoch(vaultId);
    }

    function swap(bool zeroForOne, uint256 amountIn) internal {
        vm.prank(trader);
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, key, "", trader, vm.getBlockTimestamp() + 1);
    }

    /// @dev Range of `halfWidth` ticks on each side of `center`, aligned to tick spacing.
    function rangeAround(int24 center, int24 halfWidth) internal pure returns (int24 lower, int24 upper) {
        int24 c = (center / 60) * 60;
        lower = c - halfWidth;
        upper = c + halfWidth;
    }

    function _fund(address user) internal {
        usdc.mint(user, 100_000_000e6);
        weth.mint(user, 100_000 ether);
        vm.startPrank(user);
        usdc.approve(address(hook), type(uint256).max);
        weth.approve(address(hook), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(permit2), type(uint256).max);
        weth.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }
}
