// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title PerformanceLib
/// @notice Valuation helpers. Every value is denominated in the bond token.
/// @dev Share math, position amounts, bond-token valuation, and the per-epoch benchmark and slash.
library PerformanceLib {
    uint256 internal constant BPS = 10_000;

    /// @notice Virtual shares/assets offset against first-deposit inflation attacks.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @notice Shares minted for `depositValue` given the vault state. Rounds down (in favor of the vault).
    function sharesForDeposit(uint256 depositValue, uint256 totalShares, uint256 vaultValue)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(depositValue, totalShares + VIRTUAL_SHARES, vaultValue + VIRTUAL_ASSETS);
    }

    /// @notice Pro-rata part `amount * shares / totalShares`. Rounds down (in favor of the vault).
    function proRata(uint256 amount, uint256 shares, uint256 totalShares) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, shares, totalShares);
    }

    /// @notice Token amounts held by `liquidity` in [sqrtPriceA, sqrtPriceB) at `sqrtPriceX96`, rounded down.
    function amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceBX96, liquidity, false);
        }
    }

    /// @notice Value of (amount0, amount1) in bond-token units at `sqrtPriceX96` (price of token0 in token1).
    /// @param bondIsToken0 True if currency0 is the bond token.
    /// @param roundUp Rounding direction of the price conversion of the non-bond side.
    function valueInBond(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96, bool bondIsToken0, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (bondIsToken0) {
            // token1 -> token0: amount1 / P = amount1 * Q96^2 / sqrtP^2
            uint256 converted = roundUp
                ? FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
                )
                : FullMath.mulDiv(
                    FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
                );
            return amount0 + converted;
        } else {
            // token0 -> token1: amount0 * P = amount0 * sqrtP^2 / Q96^2
            uint256 converted = roundUp
                ? FullMath.mulDivRoundingUp(
                    FullMath.mulDivRoundingUp(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
                )
                : FullMath.mulDiv(
                    FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
                );
            return amount1 + converted;
        }
    }

    /// @notice Value of a passive full-range position held over the epoch, scaled to the current shares:
    ///         `V_bench = v0 * shares / s0 * sqrt(P / P0)`, where P is the price of the non-bond token in the bond
    ///         token. Rounds up (in favor of the vault's LPs).
    /// @param v0 Vault value at the start of the epoch (bond token).
    /// @param s0 Total shares at the start of the epoch (> 0).
    /// @param shares Current total shares.
    /// @param sqrtPrice0X96 TWAP sqrtPrice (token1 per token0) at the start of the epoch.
    /// @param sqrtPriceX96 TWAP sqrtPrice (token1 per token0) now.
    /// @param bondIsToken0 True if currency0 is the bond token (then P = 1 / price, so the ratio inverts).
    function benchmarkValue(
        uint256 v0,
        uint256 s0,
        uint256 shares,
        uint160 sqrtPrice0X96,
        uint160 sqrtPriceX96,
        bool bondIsToken0
    ) internal pure returns (uint256) {
        uint256 scaled = FullMath.mulDivRoundingUp(v0, shares, s0);
        return bondIsToken0
            ? FullMath.mulDivRoundingUp(scaled, sqrtPrice0X96, sqrtPriceX96)
            : FullMath.mulDivRoundingUp(scaled, sqrtPriceX96, sqrtPrice0X96);
    }

    /// @notice `min(bond, max(0, bench - value - bench * toleranceBps) * slashRatioBps)`, ratio rounded up.
    /// @dev With slashRatioBps < BPS the result never exceeds the shortfall beyond tolerance.
    function slashAmount(uint256 bench, uint256 value, uint256 toleranceBps, uint256 slashRatioBps, uint256 bond)
        internal
        pure
        returns (uint256 slash)
    {
        uint256 floor = value + (bench * toleranceBps) / BPS;
        if (floor >= bench) return 0;
        slash = FullMath.mulDivRoundingUp(bench - floor, slashRatioBps, BPS);
        if (slash > bond) slash = bond;
    }
}
