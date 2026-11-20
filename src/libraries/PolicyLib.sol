// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PolicyLib
/// @notice Per-vault rebalancing policy and the platform-wide bounds every policy must respect.
/// @dev Bounds are compile-time constants: no admin can change them.
library PolicyLib {
    /// @notice Rules the operator of a vault must follow when calling `rebalance()`.
    /// @param maxRangeDeviationTicks Max distance (ticks) between the new range center and the TWAP tick.
    /// @param maxSpotTwapDeviationBps Max distance between spot and TWAP at execution time, measured in ticks
    ///        (1 tick = 1.0001x price, i.e. ~1 bp).
    /// @param cooldown Minimum seconds between two rebalances.
    /// @param maxRebalancesPerEpoch Max rebalances inside one epoch.
    /// @param minWidthTicks Minimum range width (tickUpper - tickLower).
    /// @param maxWidthTicks Maximum range width (tickUpper - tickLower).
    /// @param epochLength Seconds between settlements.
    struct Policy {
        uint24 maxRangeDeviationTicks;
        uint24 maxSpotTwapDeviationBps;
        uint32 cooldown;
        uint16 maxRebalancesPerEpoch;
        uint24 minWidthTicks;
        uint24 maxWidthTicks;
        uint32 epochLength;
    }

    // ------------------------------------------------------------------
    // Platform bounds
    // ------------------------------------------------------------------

    uint24 internal constant MAX_RANGE_DEVIATION_TICKS = 2_000; // ~20% price
    uint24 internal constant MIN_SPOT_TWAP_DEVIATION_BPS = 10;
    uint24 internal constant MAX_SPOT_TWAP_DEVIATION_BPS = 500;
    uint32 internal constant MAX_COOLDOWN = 1 days;
    uint16 internal constant MAX_REBALANCES_PER_EPOCH = 100;
    uint24 internal constant MIN_WIDTH_TICKS = 60;
    uint24 internal constant MAX_WIDTH_TICKS = 200_000;
    uint32 internal constant MIN_EPOCH_LENGTH = 60; // minutes-long epochs for the testnet demo
    uint32 internal constant MAX_EPOCH_LENGTH = 30 days;

    error InvalidPolicy();

    /// @notice Reverts with `InvalidPolicy` unless `p` is within platform bounds.
    /// @param p The policy to validate.
    /// @param tickSpacing Tick spacing of the pool; widths must be able to hold at least one spacing.
    function validate(Policy memory p, int24 tickSpacing) internal pure {
        bool ok = p.maxRangeDeviationTicks <= MAX_RANGE_DEVIATION_TICKS
            && p.maxSpotTwapDeviationBps >= MIN_SPOT_TWAP_DEVIATION_BPS
            && p.maxSpotTwapDeviationBps <= MAX_SPOT_TWAP_DEVIATION_BPS && p.cooldown <= MAX_COOLDOWN
            && p.maxRebalancesPerEpoch >= 1 && p.maxRebalancesPerEpoch <= MAX_REBALANCES_PER_EPOCH
            && p.minWidthTicks >= MIN_WIDTH_TICKS && p.maxWidthTicks <= MAX_WIDTH_TICKS
            && p.minWidthTicks <= p.maxWidthTicks && int256(uint256(p.minWidthTicks)) >= int256(tickSpacing)
            && p.epochLength >= MIN_EPOCH_LENGTH && p.epochLength <= MAX_EPOCH_LENGTH;
        if (!ok) revert InvalidPolicy();
    }
}
