// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title PerformanceLib
/// @notice Valuation helpers. Every value is denominated in the bond token.
/// @dev M1 subset: token amounts for a position and conversion of (amount0, amount1) to bond-token value.
///      Benchmark and in-range ratio land in M2.
library PerformanceLib {
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
}
