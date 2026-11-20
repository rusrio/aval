// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapLib} from "../../src/libraries/TwapLib.sol";

contract TwapHarness {
    using TwapLib for TwapLib.Oracle;

    TwapLib.Oracle internal oracle;

    function initialize() external {
        oracle.initialize();
    }

    function update(int24 tick, uint32 granularity) external {
        oracle.update(tick, granularity);
    }

    function consult(int24 tick, uint32 window) external view returns (int24) {
        return oracle.consult(tick, window);
    }

    function isWarm(uint32 window) external view returns (bool) {
        return oracle.isWarm(window);
    }

    function count() external view returns (uint8) {
        return oracle.count;
    }
}

contract TwapLibTest is Test {
    TwapHarness h;
    uint32 constant WINDOW = 300;
    uint32 constant GRAN = WINDOW / 8;

    function setUp() public {
        vm.warp(1_700_000_000);
        h = new TwapHarness();
        h.initialize();
    }

    function test_notWarmBeforeWindow() public {
        vm.warp(vm.getBlockTimestamp() + WINDOW - 1);
        assertFalse(h.isWarm(WINDOW));
        vm.expectRevert(TwapLib.TwapNotWarm.selector);
        h.consult(0, WINDOW);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(h.isWarm(WINDOW));
    }

    function testFuzz_constantTick(int24 tick, uint32 dt) public {
        tick = int24(bound(tick, -887_272, 887_272));
        dt = uint32(bound(dt, WINDOW, 30 days));
        vm.warp(vm.getBlockTimestamp() + dt);
        assertEq(h.consult(tick, WINDOW), tick);
    }

    /// Tick A for the first part of the window, tick B afterwards: TWAP is the time-weighted mean.
    function testFuzz_twoTicks(int24 a, int24 b, uint32 tB) public {
        a = int24(bound(a, -100_000, 100_000));
        b = int24(bound(b, -100_000, 100_000));
        tB = uint32(bound(tB, 1, WINDOW - 1));

        // tick a prevails since init; checkpoint exactly WINDOW ago
        vm.warp(vm.getBlockTimestamp() + WINDOW - tB);
        h.update(a, GRAN); // accumulates `a` up to now; from now on tick is b
        vm.warp(vm.getBlockTimestamp() + tB);

        // Checkpoint used is the init one (exactly WINDOW old).
        int256 expected = (int256(a) * int256(uint256(WINDOW - tB)) + int256(b) * int256(uint256(tB)));
        int256 avg = expected / int256(uint256(WINDOW));
        if (expected < 0 && expected % int256(uint256(WINDOW)) != 0) avg--;
        assertEq(h.consult(b, WINDOW), avg);
    }

    function test_updateOncePerBlock() public {
        vm.warp(vm.getBlockTimestamp() + 100);
        h.update(10, GRAN);
        h.update(1_000_000, GRAN); // same timestamp: ignored
        vm.warp(vm.getBlockTimestamp() + WINDOW);
        // Window covers only the extrapolated period at tick 10; the same-block update is ignored.
        assertEq(h.consult(10, WINDOW), 10);
    }

    function test_ringBufferCoversWindowUnderHeavyActivity() public {
        // A swap every second for 3 windows: the buffer must still find a checkpoint >= WINDOW old.
        for (uint256 i; i < 3 * WINDOW; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1);
            h.update(int24(int256(i % 7)), GRAN);
        }
        assertTrue(h.isWarm(WINDOW));
        assertEq(h.count(), TwapLib.CARDINALITY);
        h.consult(3, WINDOW);
    }
}
