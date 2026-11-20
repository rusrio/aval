// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PerformanceLib} from "../../src/libraries/PerformanceLib.sol";

contract PerformanceLibFuzzTest is Test {
    uint256 constant VS = PerformanceLib.VIRTUAL_SHARES;

    function _price(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(int24(bound(tick, -400_000, 400_000)));
    }

    /// First deposit into an empty vault mints value * VIRTUAL_SHARES.
    function testFuzz_firstDeposit(uint128 d) public pure {
        assertEq(PerformanceLib.sharesForDeposit(d, 0, 0), uint256(d) * VS);
    }

    /// Depositing then immediately redeeming pro-rata never returns more than deposited,
    /// up to the documented virtual-offset leak of d * VIRTUAL_SHARES / S (OZ ERC-4626 trade-off).
    function testFuzz_depositRedeemNoProfit(uint128 d, uint128 v, uint128 sRaw) public pure {
        vm.assume(d > 0 && v > 0);
        uint256 s0 = bound(sRaw, 1, type(uint128).max);
        uint256 minted = PerformanceLib.sharesForDeposit(d, s0, v);
        vm.assume(minted > 0);
        uint256 redeem = PerformanceLib.proRata(uint256(v) + d, minted, s0 + minted);
        assertLe(redeem, uint256(d) + (uint256(d) * VS) / s0 + 1);
        // When the vault is at or below the initial share price, no leak at all.
        if (s0 >= uint256(v) * VS) assertLe(redeem, d);
    }

    /// More value deposited never yields fewer shares.
    function testFuzz_sharesMonotonic(uint128 d1, uint128 d2, uint128 s, uint128 v) public pure {
        (uint256 lo, uint256 hi) = d1 <= d2 ? (d1, d2) : (d2, d1);
        assertLe(PerformanceLib.sharesForDeposit(lo, s, v), PerformanceLib.sharesForDeposit(hi, s, v));
    }

    /// Pro-rata never exceeds the whole, and parts never exceed the whole.
    function testFuzz_proRataBounded(uint128 amount, uint128 a, uint128 b) public pure {
        uint256 total = uint256(a) + b;
        vm.assume(total > 0);
        uint256 pa = PerformanceLib.proRata(amount, a, total);
        uint256 pb = PerformanceLib.proRata(amount, b, total);
        assertLe(pa + pb, amount);
    }

    /// Valuation rounding: roundUp >= roundDown; the gap is bounded by the two nested roundings
    /// (the inner one amplified by the price factor of the outer multiplication).
    function testFuzz_valueRounding(uint96 a0, uint96 a1, int24 tick, bool bond0) public pure {
        uint160 p = _price(tick);
        uint256 down = PerformanceLib.valueInBond(a0, a1, p, bond0, false);
        uint256 up = PerformanceLib.valueInBond(a0, a1, p, bond0, true);
        assertGe(up, down);
        uint256 amp = bond0 ? (uint256(1) << 96) / p : uint256(p) >> 96;
        assertLe(up - down, 2 + amp);
    }

    /// Valuation is superadditive when rounding down: per-user claims never exceed the aggregate mint.
    function testFuzz_valueSuperadditive(uint96 x0, uint96 x1, uint96 y0, uint96 y1, int24 tick, bool bond0)
        public
        pure
    {
        uint160 p = _price(tick);
        uint256 whole = PerformanceLib.valueInBond(uint256(x0) + y0, uint256(x1) + y1, p, bond0, false);
        uint256 parts =
            PerformanceLib.valueInBond(x0, x1, p, bond0, false) + PerformanceLib.valueInBond(y0, y1, p, bond0, false);
        assertGe(whole, parts);
    }

    /// Position amounts are bounded by the amounts of the full [A, B) range.
    function testFuzz_amountsForLiquidityBounded(int24 t, int24 lo, int24 hi, uint128 liq) public pure {
        int24 l = int24(bound(lo, -100_000, 99_000));
        int24 u = int24(bound(hi, int256(l) + 60, 100_000));
        uint160 sa = TickMath.getSqrtPriceAtTick(l);
        uint160 sb = TickMath.getSqrtPriceAtTick(u);
        uint160 p = TickMath.getSqrtPriceAtTick(int24(bound(t, -110_000, 110_000)));
        (uint256 a0, uint256 a1) = PerformanceLib.amountsForLiquidity(p, sa, sb, liq);
        (uint256 max0,) = PerformanceLib.amountsForLiquidity(sa, sa, sb, liq);
        (, uint256 max1) = PerformanceLib.amountsForLiquidity(sb, sa, sb, liq);
        assertLe(a0, max0);
        assertLe(a1, max1);
    }
}
