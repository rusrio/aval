// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TwapLib
/// @notice Per-pool tick accumulator (v3-oracle style) plus a small ring buffer of checkpoints.
/// @dev The accumulator is updated at most once per block (first swap of the block, pre-swap tick).
///      Checkpoints are pushed only every `granularity` seconds so a fixed-size buffer always covers the
///      TWAP window. Reads extrapolate the accumulator with the current tick, so the TWAP stays correct
///      when there are no swaps. The effective window of `consult` is in [window, window + granularity].
library TwapLib {
    uint256 internal constant CARDINALITY = 16;

    struct Checkpoint {
        uint32 timestamp;
        int64 tickCumulative;
    }

    struct Oracle {
        uint32 lastTimestamp;
        int64 tickCumulative;
        uint8 index; // newest checkpoint
        uint8 count; // populated checkpoints
        Checkpoint[CARDINALITY] checkpoints;
    }

    error OracleNotInitialized();
    error TwapNotWarm();

    /// @notice Starts the oracle at the current block timestamp.
    function initialize(Oracle storage self) internal {
        uint32 ts = uint32(block.timestamp);
        self.lastTimestamp = ts;
        self.tickCumulative = 0;
        self.index = 0;
        self.count = 1;
        self.checkpoints[0] = Checkpoint(ts, 0);
    }

    /// @notice Accumulates `tick` (the tick that prevailed since the last update) up to now.
    /// @dev O(1). No-op if already updated in this block.
    /// @param tick Current pool tick before the swap.
    /// @param granularity Minimum seconds between checkpoints.
    function update(Oracle storage self, int24 tick, uint32 granularity) internal {
        uint32 ts = uint32(block.timestamp);
        uint32 last = self.lastTimestamp;
        if (ts == last) return;
        if (self.count == 0) revert OracleNotInitialized();

        int64 cumulative = self.tickCumulative + int64(tick) * int64(uint64(ts - last));
        self.tickCumulative = cumulative;
        self.lastTimestamp = ts;

        uint8 index = self.index;
        if (ts - self.checkpoints[index].timestamp >= granularity) {
            uint8 next = uint8((uint256(index) + 1) % CARDINALITY);
            self.checkpoints[next] = Checkpoint(ts, cumulative);
            self.index = next;
            if (self.count < CARDINALITY) self.count++;
        }
    }

    /// @notice Tick cumulative extrapolated to the current timestamp with `currentTick`.
    function cumulativeNow(Oracle storage self, int24 currentTick) internal view returns (int64) {
        return self.tickCumulative + int64(currentTick) * int64(uint64(uint32(block.timestamp) - self.lastTimestamp));
    }

    /// @notice True if a checkpoint at least `window` seconds old exists.
    function isWarm(Oracle storage self, uint32 window) internal view returns (bool) {
        (bool found,) = _findCheckpoint(self, window);
        return found;
    }

    /// @notice Time-weighted average tick over (at least) the last `window` seconds.
    /// @dev Rounds toward negative infinity. Reverts with `TwapNotWarm` if history is too short.
    function consult(Oracle storage self, int24 currentTick, uint32 window) internal view returns (int24) {
        (bool ok, int24 tick) = tryConsult(self, currentTick, window);
        if (!ok) revert TwapNotWarm();
        return tick;
    }

    /// @notice Like `consult`, but returns `ok = false` instead of reverting when not warm.
    function tryConsult(Oracle storage self, int24 currentTick, uint32 window)
        internal
        view
        returns (bool ok, int24 twapTick)
    {
        (bool found, Checkpoint memory ck) = _findCheckpoint(self, window);
        if (!found) return (false, 0);

        int64 delta = cumulativeNow(self, currentTick) - ck.tickCumulative;
        int64 elapsed = int64(uint64(uint32(block.timestamp) - ck.timestamp));
        int64 avg = delta / elapsed;
        if (delta < 0 && delta % elapsed != 0) avg--;
        return (true, int24(avg));
    }

    /// @dev Newest checkpoint with timestamp <= now - window. Bounded by CARDINALITY iterations.
    function _findCheckpoint(Oracle storage self, uint32 window)
        private
        view
        returns (bool found, Checkpoint memory ck)
    {
        uint32 nowTs = uint32(block.timestamp);
        if (window == 0 || nowTs < window) return (false, ck);
        uint32 target = nowTs - window;
        uint256 count = self.count;
        uint256 index = self.index;
        for (uint256 i; i < count; ++i) {
            ck = self.checkpoints[(index + CARDINALITY - i) % CARDINALITY];
            if (ck.timestamp <= target) return (true, ck);
        }
        return (false, ck);
    }
}
