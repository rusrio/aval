// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PerformanceLib} from "../../src/libraries/PerformanceLib.sol";

/// @notice Benchmark V_bench = V_0 * (S / S_0) * sqrt(P / P_0) and slash = min(bond, shortfall * ratio).
contract BenchmarkFuzzTest is Test {
    uint160 constant SQRT_P0 = 79228162514264337593543950336; // 2^96 (price 1)

    function _price(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(int24(bound(tick, -200_000, 200_000)));
    }

    // ------------------------------------------------------------------
    // Benchmark
    // ------------------------------------------------------------------

    function test_benchmark_samePriceSameShares() public pure {
        assertEq(PerformanceLib.benchmarkValue(1_000e6, 5e12, 5e12, SQRT_P0, SQRT_P0, false), 1_000e6);
        assertEq(PerformanceLib.benchmarkValue(1_000e6, 5e12, 5e12, SQRT_P0, SQRT_P0, true), 1_000e6);
    }

    /// Price of token0 in token1 x4 (sqrt x2). Bond = token1: non-bond token up 4x -> benchmark x2.
    /// Bond = token0: non-bond token (token1) down 4x -> benchmark /2.
    function test_benchmark_followsSqrtOfNonBondPrice() public pure {
        uint160 sqrtP = SQRT_P0 * 2;
        assertEq(PerformanceLib.benchmarkValue(1_000e6, 1e12, 1e12, SQRT_P0, sqrtP, false), 2_000e6);
        assertEq(PerformanceLib.benchmarkValue(1_000e6, 1e12, 1e12, SQRT_P0, sqrtP, true), 500e6);
    }

    /// Withdrawals scale the benchmark with the remaining shares (comparison is per share).
    function test_benchmark_scalesWithShares() public pure {
        assertEq(PerformanceLib.benchmarkValue(1_000e6, 1e12, 25e10, SQRT_P0, SQRT_P0, false), 250e6);
    }

    /// The benchmark of the bond-side numeraire moves in opposite directions for the two token orderings.
    function testFuzz_benchmark_directionByOrdering(uint96 v0, int24 t0, int24 t1) public pure {
        vm.assume(v0 > 1e6);
        uint160 p0 = _price(t0);
        uint160 p1 = _price(t1);
        vm.assume(p1 > p0);
        assertGe(PerformanceLib.benchmarkValue(v0, 1e12, 1e12, p0, p1, false), v0, "bond1: token0 up");
        assertLe(PerformanceLib.benchmarkValue(v0, 1e12, 1e12, p0, p1, true), uint256(v0) + 1, "bond0: token1 down");
    }

    /// Round trip: moving away and back gives (up to rounding) the starting value.
    function testFuzz_benchmark_pathIndependent(uint96 v0Raw, int24 t0, int24 t1, bool bond0) public pure {
        uint256 v0 = bound(v0Raw, 1e18, type(uint96).max);
        uint160 p0 = TickMath.getSqrtPriceAtTick(int24(bound(t0, -100_000, 100_000)));
        uint160 p1 = TickMath.getSqrtPriceAtTick(int24(bound(t1, -100_000, 100_000)));
        uint256 there = PerformanceLib.benchmarkValue(v0, 1, 1, p0, p1, bond0);
        uint256 direct = PerformanceLib.benchmarkValue(v0, 1, 1, p0, p0, bond0);
        assertEq(direct, v0);
        // there * sqrt(p0/p1) ~= v0 (rounded up twice)
        uint256 back = PerformanceLib.benchmarkValue(there, 1, 1, p1, p0, bond0);
        assertGe(back, v0);
        assertApproxEqRel(back, v0, 1e12);
    }

    // ------------------------------------------------------------------
    // Slash
    // ------------------------------------------------------------------

    function test_slash_zeroAtOrAboveBenchmark() public pure {
        assertEq(PerformanceLib.slashAmount(1_000e6, 1_000e6, 0, 5_000, 1e12), 0);
        assertEq(PerformanceLib.slashAmount(1_000e6, 1_200e6, 0, 5_000, 1e12), 0);
    }

    function test_slash_zeroWithinTolerance() public pure {
        // 1% tolerance on 1,000 = 10
        assertEq(PerformanceLib.slashAmount(1_000e6, 990e6, 100, 5_000, 1e12), 0);
        assertEq(PerformanceLib.slashAmount(1_000e6, 990e6 - 2, 100, 5_000, 1e12), 1);
    }

    function test_slash_ratioOfShortfallBeyondTolerance() public pure {
        // shortfall = 1000 - 900 - 10 = 90; 50% -> 45
        assertEq(PerformanceLib.slashAmount(1_000e6, 900e6, 100, 5_000, 1e12), 45e6);
    }

    function test_slash_cappedAtBond() public pure {
        assertEq(PerformanceLib.slashAmount(1_000e6, 0, 0, 9_000, 100e6), 100e6);
        assertEq(PerformanceLib.slashAmount(1_000e6, 0, 0, 9_000, 0), 0);
    }

    /// Invariant 4: slash <= bond, and never more than the shortfall beyond tolerance.
    function testFuzz_slash_bounded(uint128 bench, uint128 value, uint16 tolRaw, uint16 ratioRaw, uint128 bond)
        public
        pure
    {
        uint256 tol = bound(tolRaw, 0, 500);
        uint256 ratio = bound(ratioRaw, 1_000, 9_000);
        uint256 s = PerformanceLib.slashAmount(bench, value, tol, ratio, bond);
        assertLe(s, bond);
        uint256 floor = uint256(value) + (uint256(bench) * tol) / 10_000;
        if (floor >= bench) assertEq(s, 0);
        else assertLe(s, bench - floor);
    }

    /// A worse vault value never yields a smaller slash.
    function testFuzz_slash_monotonicInValue(uint128 bench, uint128 v1, uint128 v2, uint16 tolRaw, uint128 bond)
        public
        pure
    {
        uint256 tol = bound(tolRaw, 0, 500);
        (uint128 lo, uint128 hi) = v1 < v2 ? (v1, v2) : (v2, v1);
        assertGe(
            PerformanceLib.slashAmount(bench, lo, tol, 5_000, bond),
            PerformanceLib.slashAmount(bench, hi, tol, 5_000, bond)
        );
    }
}
