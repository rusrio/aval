// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";
import {PerformanceLib} from "../../src/libraries/PerformanceLib.sol";

contract AvalHookFuzzTest is AvalFixture {
    function _bounded(uint256 usdcRaw, uint256 wethRaw) internal pure returns (uint256 u, uint256 w) {
        u = bound(usdcRaw, 0, 10_000_000e6);
        w = bound(wethRaw, 0, 3_000 ether);
        if (u == 0 && w == 0) u = 1e6;
    }

    /// Sum of claimed shares never exceeds the shares minted at settlement.
    function testFuzz_claimsNeverExceedMinted(uint256 au, uint256 aw, uint256 bu, uint256 bw) public {
        (au, aw) = _bounded(au, aw);
        (bu, bw) = _bounded(bu, bw);
        uint256 id = createDefaultVault();
        depositAs(alice, id, au, aw);
        depositAs(bob, id, bu, bw);
        settleAfterEpoch(id);
        vm.prank(alice);
        hook.claimShares(id);
        vm.prank(bob);
        hook.claimShares(id);
        assertLe(hook.sharesOf(id, alice) + hook.sharesOf(id, bob), hook.getVault(id).totalShares);
    }

    /// A later depositor who withdraws right away never gets more value (at TWAP) than they put in.
    function testFuzz_depositWithdrawNoProfit(uint256 bu, uint256 bw, int24 offsetRaw) public {
        (bu, bw) = _bounded(bu, bw);
        uint256 id = createDefaultVault();
        depositAs(alice, id, 30_000e6, 10 ether);
        settleAfterEpoch(id);
        int24 offset = int24(bound(offsetRaw, -9, 9)) * 60; // within maxRangeDeviationTicks
        (int24 lower, int24 upper) = rangeAround(spotTick() + offset, 1200);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);

        depositAs(bob, id, bu, bw);
        settleAfterEpoch(id);
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(hook.getTwapTick(poolId));
        (uint256 d0, uint256 d1) = amounts(bu, bw);
        uint256 depositValue = PerformanceLib.valueInBond(d0, d1, sqrtTwap, usdcIs0, false);

        vm.prank(bob);
        hook.claimShares(id);
        uint256 shares = hook.sharesOf(id, bob);
        vm.assume(shares > 0);
        vm.prank(bob);
        (uint256 o0, uint256 o1) = hook.withdraw(id, shares, 0, 0);
        uint256 outValue = PerformanceLib.valueInBond(o0, o1, sqrtTwap, usdcIs0, false);

        // Allow the spot/TWAP divergence of the deployed part (< 1 tick) plus rounding.
        assertLe(outValue, depositValue + depositValue / 1e6 + 10);
    }

    /// Withdrawing everything leaves no shares, liquidity or idle balances.
    function testFuzz_fullExitLeavesVaultEmpty(uint256 au, uint256 aw) public {
        (au, aw) = _bounded(au, aw);
        uint256 id = createDefaultVault();
        depositAs(alice, id, au, aw);
        settleAfterEpoch(id);
        vm.prank(alice);
        hook.claimShares(id);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);

        uint256 shares = hook.sharesOf(id, alice);
        vm.assume(shares > 0); // dust deposits worth < 1 bond-token unit mint no shares
        vm.prank(alice);
        hook.withdraw(id, shares, 0, 0);
        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.totalShares, 0);
        assertEq(v.liquidity, 0);
        assertEq(v.idle0, 0);
        assertEq(v.idle1, 0);
        // Only rounding dust stays in the hook.
        assertLe(usdc.balanceOf(address(hook)), 10);
        assertLe(weth.balanceOf(address(hook)), 10);
    }
}
