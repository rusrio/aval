// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";
import {PolicyLib} from "../../src/libraries/PolicyLib.sol";
import {PerformanceLib} from "../../src/libraries/PerformanceLib.sol";

/// @notice Benchmark vs a passive full-range position and slashing in `settleEpoch`.
contract SlashingTest is AvalFixture {
    event Slashed(uint256 indexed vaultId, uint64 indexed epoch, uint256 amount);

    address internal carol = makeAddr("carol");

    uint256 internal honest;
    uint256 internal lazy;

    function setUp() public override {
        super.setUp();
        _fund(carol);
        // Honest vault provides the pool's liquidity (so swaps can move the price).
        honest = createDefaultVault();
        // Lazy vault: 30k USDC, never deployed. Loses to the benchmark whenever ETH rises.
        lazy = createDefaultVault();
        depositAs(alice, honest, 300_000e6, 100 ether);
        depositAs(bob, lazy, 30_000e6, 0);
        warpAndRoll(defaultPolicy().epochLength);
        hook.settleEpoch(honest);
        hook.settleEpoch(lazy);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 6000);
        vm.prank(operator);
        hook.rebalance(honest, lower, upper);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Moves ETH up (sell USDC) or down (sell WETH), then lets the epoch and the TWAP window pass.
    function _moveEthPrice(bool up) internal {
        if (up) swap(usdcIs0, 30_000e6);
        else swap(!usdcIs0, 10 ether);
        warpAndRoll(defaultPolicy().epochLength);
    }

    function _expectedSlash(uint256 vaultId) internal view returns (uint256) {
        (uint256 bench, uint256 value) = hook.getPerformance(vaultId);
        PolicyLib.Policy memory p = defaultPolicy();
        return PerformanceLib.slashAmount(bench, value, p.toleranceBps, p.slashRatioBps, hook.getVault(vaultId).bond);
    }

    function _idleUsdc(uint256 vaultId) internal view returns (uint256) {
        AvalHook.Vault memory v = hook.getVault(vaultId);
        return usdcIs0 ? v.idle0 : v.idle1;
    }

    function _shareValue(uint256 vaultId, address user) internal view returns (uint256) {
        return hook.getVaultValue(vaultId) * hook.sharesOf(vaultId, user) / hook.getVault(vaultId).totalShares;
    }

    // ------------------------------------------------------------------
    // Benchmark
    // ------------------------------------------------------------------

    function test_firstEpoch_noBenchmark() public {
        uint256 id = createDefaultVault();
        depositAs(carol, id, 10_000e6, 0);
        (uint256 bench,) = hook.getPerformance(id);
        assertEq(bench, 0, "no shares at epoch start");
        uint256 bondBefore = hook.getVault(id).bond;
        _moveEthPrice(true);
        hook.settleEpoch(id);
        assertEq(hook.getVault(id).bond, bondBefore);
    }

    function test_benchmark_startsAtVaultValue() public view {
        (uint256 bench, uint256 value) = hook.getPerformance(lazy);
        assertApproxEqRel(bench, value, 1e12);
    }

    function test_benchmark_risesWithEthForUsdcBond() public {
        (uint256 before,) = hook.getPerformance(lazy);
        _moveEthPrice(true);
        (uint256 bench, uint256 value) = hook.getPerformance(lazy);
        assertGt(bench, before);
        assertEq(value, 30_000e6, "idle USDC does not move");
    }

    function test_benchmark_perShare_unaffectedByWithdrawals() public {
        _moveEthPrice(true);
        (uint256 bench, uint256 value) = hook.getPerformance(lazy);
        vm.startPrank(bob);
        hook.claimShares(lazy);
        hook.withdraw(lazy, hook.sharesOf(lazy, bob) / 2, 0, 0);
        vm.stopPrank();
        (uint256 bench2, uint256 value2) = hook.getPerformance(lazy);
        assertApproxEqRel(bench2 * 2, bench, 1e9);
        assertApproxEqRel(value2 * 2, value, 1e9);
    }

    function test_benchmark_resetsAtSettlement() public {
        _moveEthPrice(true);
        hook.settleEpoch(lazy);
        (uint256 bench, uint256 value) = hook.getPerformance(lazy);
        assertApproxEqRel(bench, value, 1e12);
    }

    // ------------------------------------------------------------------
    // Slashing
    // ------------------------------------------------------------------

    function test_slash_lazyVaultWhenEthRises() public {
        _moveEthPrice(true);
        (, uint256 valueBefore) = hook.getPerformance(lazy);
        uint256 expected = _expectedSlash(lazy);
        assertGt(expected, 0);
        uint256 bondBefore = hook.getVault(lazy).bond;
        uint256 idleBefore = _idleUsdc(lazy);

        vm.expectEmit(true, true, false, true, address(hook));
        emit Slashed(lazy, 1, expected);
        hook.settleEpoch(lazy);

        assertEq(hook.getVault(lazy).bond, bondBefore - expected, "bond reduced");
        assertEq(_idleUsdc(lazy), idleBefore + expected, "slash lands in idle bond token");
        assertEq(hook.getVaultValue(lazy), valueBefore + expected, "share price rises");
    }

    function test_slash_followsPolicyRatioAndTolerance() public {
        _moveEthPrice(true);
        (uint256 bench, uint256 value) = hook.getPerformance(lazy);
        uint256 shortfall = bench - value - bench * defaultPolicy().toleranceBps / 10_000;
        assertApproxEqAbs(_expectedSlash(lazy), shortfall / 2, 1, "50% of the shortfall beyond 1% tolerance");
    }

    function test_noSlash_lazyVaultWhenEthFalls() public {
        _moveEthPrice(false);
        uint256 bondBefore = hook.getVault(lazy).bond;
        hook.settleEpoch(lazy);
        assertEq(hook.getVault(lazy).bond, bondBefore);
    }

    /// Holding 50/50 always beats a full-range position (no IL), so it is never slashed.
    function test_noSlash_holdVault() public {
        uint256 hold = createDefaultVault();
        depositAs(carol, hold, 15_000e6, 5 ether);
        warpAndRoll(defaultPolicy().epochLength);
        hook.settleEpoch(hold);
        uint256 bondBefore = hook.getVault(hold).bond;

        _moveEthPrice(true);
        hook.settleEpoch(hold);
        _moveEthPrice(false);
        hook.settleEpoch(hold);
        assertEq(hook.getVault(hold).bond, bondBefore);
    }

    function test_slash_queuedDepositorDoesNotCapture() public {
        _moveEthPrice(true);
        depositAs(carol, lazy, 10_000e6, 0);
        uint256 slash = _expectedSlash(lazy);
        (, uint256 bobValueBefore) = hook.getPerformance(lazy);
        hook.settleEpoch(lazy);
        vm.prank(carol);
        hook.claimShares(lazy);
        vm.prank(bob);
        hook.claimShares(lazy);

        assertApproxEqRel(_shareValue(lazy, carol), 10_000e6, 1e12, "new LP enters at post-slash price");
        assertApproxEqRel(_shareValue(lazy, bob), bobValueBefore + slash, 1e12, "slash goes to existing LPs");
    }

    function test_slash_emptyVaultNotSlashed() public {
        _moveEthPrice(true);
        vm.startPrank(bob);
        hook.claimShares(lazy);
        hook.withdraw(lazy, hook.sharesOf(lazy, bob), 0, 0);
        vm.stopPrank();
        uint256 bondBefore = hook.getVault(lazy).bond;
        hook.settleEpoch(lazy);
        assertEq(hook.getVault(lazy).bond, bondBefore);
    }

    // ------------------------------------------------------------------
    // Policy bounds
    // ------------------------------------------------------------------

    function test_revert_policy_toleranceAboveMax() public {
        PolicyLib.Policy memory p = defaultPolicy();
        p.toleranceBps = 501;
        vm.expectRevert(PolicyLib.InvalidPolicy.selector);
        hook.createVault(key, p, operator, DEFAULT_BOND, initSqrtPrice);
    }

    function test_revert_policy_slashRatioOutOfBounds() public {
        PolicyLib.Policy memory p = defaultPolicy();
        p.slashRatioBps = 999;
        vm.expectRevert(PolicyLib.InvalidPolicy.selector);
        hook.createVault(key, p, operator, DEFAULT_BOND, initSqrtPrice);
        p.slashRatioBps = 9_001;
        vm.expectRevert(PolicyLib.InvalidPolicy.selector);
        hook.createVault(key, p, operator, DEFAULT_BOND, initSqrtPrice);
    }
}
