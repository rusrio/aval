// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";
import {AvalLens} from "../../src/AvalLens.sol";
import {PolicyLib} from "../../src/libraries/PolicyLib.sol";

/// @notice AvalLens decodes the hook's storage by hand: check every field, and check its TWAP and valuation
///         against the numbers the hook itself computes in `settleEpoch`.
contract AvalLensTest is AvalFixture {
    using StateLibrary for IPoolManager;

    bytes32 constant EPOCH_SETTLED =
        keccak256("EpochSettled(uint256,uint64,int24,uint256,uint256,uint256,uint256,uint256)");

    /// @dev Every field distinct, so a wrong offset can't decode to the right value by accident.
    function _oddPolicy() internal pure returns (PolicyLib.Policy memory) {
        return PolicyLib.Policy({
            maxRangeDeviationTicks: 1_234,
            maxSpotTwapDeviationBps: 321,
            cooldown: 77,
            maxRebalancesPerEpoch: 9,
            minWidthTicks: 180,
            maxWidthTicks: 54_321,
            epochLength: 611,
            toleranceBps: 37,
            slashRatioBps: 4_321
        });
    }

    /// @dev Settles `id` and returns the TWAP tick and vault value the hook emitted.
    function _settleAndRead(uint256 id) internal returns (int24 twapTick, uint256 vaultValue) {
        vm.recordLogs();
        hook.settleEpoch(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == EPOCH_SETTLED && uint256(logs[i].topics[1]) == id) {
                (twapTick, vaultValue) = abi.decode(logs[i].data, (int24, uint256));
                return (twapTick, vaultValue);
            }
        }
        revert("no EpochSettled");
    }

    function test_getVault_keyOwnerPolicy() public {
        PolicyLib.Policy memory p = _oddPolicy();
        vm.prank(owner);
        uint256 id = hook.createVault(key, p, operator, DEFAULT_BOND, initSqrtPrice);
        AvalHook.Vault memory v = lens.getVault(id);

        assertEq(Currency.unwrap(v.key.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(v.key.currency1), Currency.unwrap(key.currency1));
        assertEq(v.key.fee, key.fee);
        assertEq(v.key.tickSpacing, key.tickSpacing);
        assertEq(address(v.key.hooks), address(hook));
        assertEq(v.owner, owner);
        assertEq(v.operator, operator);
        assertEq(abi.encode(v.policy), abi.encode(p));
        assertEq(v.bond, DEFAULT_BOND);
        assertEq(v.epochStart, vm.getBlockTimestamp());
    }

    function test_getVault_positionAndPackedFields() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 30_000e6, 10 ether);
        settleAfterEpoch(id);
        depositAs(bob, id, 1_000e6, 1 ether); // queued
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, 7e6);

        AvalHook.Vault memory v = lens.getVault(id);
        assertEq(v.tickLower, lower);
        assertEq(v.tickUpper, upper);
        (uint128 liq,,) = poolManager.getPositionInfo(poolId, address(hook), lower, upper, bytes32(id));
        assertEq(v.liquidity, liq);
        assertGt(v.liquidity, 0);
        (uint256 p0, uint256 p1) = amounts(1_000e6, 1 ether);
        assertEq(v.pending0, p0);
        assertEq(v.pending1, p1);
        assertEq(v.epoch, 1);
        assertEq(v.lastRebalance, vm.getBlockTimestamp());
        assertEq(v.rebalancesThisEpoch, 1);
        assertEq(v.bondWithdrawalAmount, 7e6);
        assertEq(v.bondWithdrawalEpoch, 1);
        assertGt(v.benchShares0, 0);
        assertEq(v.benchShares0, v.totalShares);
        assertGt(v.benchSqrtPrice0, 0);
        assertFalse(v.safeMode);
        // Idle balances: everything not deployed, per the hook's own token balance (single vault, bond in USDC).
        (uint256 bal0, uint256 bal1) =
            amounts(usdc.balanceOf(address(hook)) - DEFAULT_BOND, weth.balanceOf(address(hook)));
        assertEq(v.idle0 + v.pending0, bal0);
        assertEq(v.idle1 + v.pending1, bal1);
    }

    function test_revert_getVault_unknown() public {
        vm.expectRevert(AvalLens.VaultNotFound.selector);
        lens.getVault(42);
    }

    /// TWAP and valuation match what the hook computes during settlement, after swaps and fee accrual.
    function test_twapAndValue_matchSettlement() public {
        uint256 id = createDefaultVault();
        depositAs(alice, id, 30_000e6, 10 ether);
        settleAfterEpoch(id);
        (int24 lower, int24 upper) = rangeAround(spotTick(), 1200);
        vm.prank(operator);
        hook.rebalance(id, lower, upper);
        for (uint256 i; i < 6; ++i) {
            swap(i % 2 == 0, i % 2 == 0 ? (usdcIs0 ? 2_000e6 : 0.5 ether) : (usdcIs0 ? 0.5 ether : 2_000e6));
            warpAndRoll(90);
        }
        warpAndRoll(defaultPolicy().epochLength);

        int24 lensTwap = lens.getTwapTick(poolId);
        uint256 lensValue = lens.getVaultValue(id);
        assertTrue(lens.isTwapWarm(poolId));
        (int24 hookTwap, uint256 hookValue) = _settleAndRead(id);
        assertEq(lensTwap, hookTwap, "TWAP");
        assertEq(lensValue, hookValue, "valuation incl. uncollected fees");
    }

    function test_twapNotWarm() public {
        createDefaultVault();
        assertFalse(lens.isTwapWarm(poolId));
        vm.expectRevert();
        lens.getTwapTick(poolId);
    }
}
