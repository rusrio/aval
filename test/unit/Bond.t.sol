// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {AvalFixture} from "../utils/AvalFixture.sol";
import {AvalHook} from "../../src/AvalHook.sol";

contract BondTest is AvalFixture {
    uint256 internal minBond;

    function setUp() public override {
        super.setUp();
        minBond = hook.MIN_BOND();
    }

    function _vaultWithBond(uint256 bond) internal returns (uint256 id) {
        vm.prank(owner);
        id = hook.createVault(key, defaultPolicy(), operator, bond, initSqrtPrice);
    }

    function _cap(uint256 bond) internal view returns (uint256) {
        return bond * hook.MAX_LEVERAGE();
    }

    // ------------------------------------------------------------------
    // Posting bond
    // ------------------------------------------------------------------

    function test_revert_createVault_bondBelowMinimum() public {
        vm.prank(owner);
        vm.expectRevert(AvalHook.BondTooLow.selector);
        hook.createVault(key, defaultPolicy(), operator, minBond - 1, initSqrtPrice);
    }

    function test_addBond_onlyOwner() public {
        uint256 id = _vaultWithBond(minBond);
        vm.prank(owner);
        hook.addBond(id, 500e6);
        assertEq(hook.getVault(id).bond, minBond + 500e6);

        vm.prank(alice);
        vm.expectRevert(AvalHook.OnlyOwner.selector);
        hook.addBond(id, 500e6);
    }

    // ------------------------------------------------------------------
    // TVL cap: maxTVL = bond * MAX_LEVERAGE
    // ------------------------------------------------------------------

    function test_deposit_upToCap() public {
        uint256 id = _vaultWithBond(minBond);
        depositAs(alice, id, _cap(minBond), 0);
        assertEq(hook.getVault(id).pending0 + hook.getVault(id).pending1, _cap(minBond));
    }

    function test_revert_deposit_aboveCap() public {
        uint256 id = _vaultWithBond(minBond);
        (uint256 a0, uint256 a1) = amounts(_cap(minBond) + 1, 0);
        vm.prank(alice);
        vm.expectRevert(AvalHook.TvlCapExceeded.selector);
        hook.deposit(id, a0, a1);
    }

    function test_revert_deposit_capCountsPendingAndActive() public {
        uint256 id = _vaultWithBond(minBond);
        depositAs(alice, id, _cap(minBond) / 2, 0);
        settleAfterEpoch(id); // active half
        depositAs(bob, id, _cap(minBond) / 4, 0); // pending quarter
        (uint256 a0, uint256 a1) = amounts(_cap(minBond) / 4 + 10e6, 0);
        vm.prank(alice);
        vm.expectRevert(AvalHook.TvlCapExceeded.selector);
        hook.deposit(id, a0, a1);
    }

    function test_addBond_raisesCap() public {
        uint256 id = _vaultWithBond(minBond);
        vm.prank(owner);
        hook.addBond(id, minBond);
        depositAs(alice, id, _cap(2 * minBond), 0);
    }

    // ------------------------------------------------------------------
    // Delayed withdrawals
    // ------------------------------------------------------------------

    function test_bondWithdrawal_delayedOneFullEpoch() public {
        uint256 id = _vaultWithBond(3 * minBond);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, minBond);

        vm.prank(owner);
        vm.expectRevert(AvalHook.BondWithdrawalLocked.selector);
        hook.executeBondWithdrawal(id);

        settleAfterEpoch(id); // closes the request epoch
        vm.prank(owner);
        vm.expectRevert(AvalHook.BondWithdrawalLocked.selector);
        hook.executeBondWithdrawal(id);

        settleAfterEpoch(id); // one full epoch of slashability elapsed
        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        hook.executeBondWithdrawal(id);
        assertEq(usdc.balanceOf(owner) - before, minBond);
        AvalHook.Vault memory v = hook.getVault(id);
        assertEq(v.bond, 2 * minBond);
        assertEq(v.bondWithdrawalAmount, 0);
    }

    function test_bondWithdrawal_newRequestResetsDelay() public {
        uint256 id = _vaultWithBond(3 * minBond);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, minBond);
        settleAfterEpoch(id);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, 2 * minBond);
        settleAfterEpoch(id);
        vm.prank(owner);
        vm.expectRevert(AvalHook.BondWithdrawalLocked.selector);
        hook.executeBondWithdrawal(id);
    }

    function test_cancelBondWithdrawal() public {
        uint256 id = _vaultWithBond(3 * minBond);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, minBond);
        vm.prank(owner);
        hook.cancelBondWithdrawal(id);
        settleAfterEpoch(id);
        settleAfterEpoch(id);
        vm.prank(owner);
        vm.expectRevert(AvalHook.NoBondWithdrawal.selector);
        hook.executeBondWithdrawal(id);
    }

    function test_revert_bondWithdrawal_breaksCap() public {
        uint256 id = _vaultWithBond(2 * minBond);
        depositAs(alice, id, _cap(minBond) + 1_000e6, 0); // needs > minBond of bond
        vm.prank(owner);
        hook.requestBondWithdrawal(id, minBond);
        settleAfterEpoch(id);
        settleAfterEpoch(id);
        vm.prank(owner);
        vm.expectRevert(AvalHook.TvlCapExceeded.selector);
        hook.executeBondWithdrawal(id);
    }

    function test_revert_bondWithdrawal_belowMinimumWithLps() public {
        uint256 id = _vaultWithBond(minBond);
        depositAs(alice, id, 1_000e6, 0);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, 1);
        settleAfterEpoch(id);
        settleAfterEpoch(id);
        vm.prank(owner);
        vm.expectRevert(AvalHook.BondTooLow.selector);
        hook.executeBondWithdrawal(id);
    }

    function test_bondWithdrawal_fullExitWhenVaultEmpty() public {
        uint256 id = _vaultWithBond(minBond);
        vm.prank(owner);
        hook.requestBondWithdrawal(id, minBond);
        settleAfterEpoch(id);
        settleAfterEpoch(id);
        vm.prank(owner);
        hook.executeBondWithdrawal(id);
        assertEq(hook.getVault(id).bond, 0);
    }

    function test_revert_bondWithdrawal_onlyOwner() public {
        uint256 id = _vaultWithBond(minBond);
        vm.prank(alice);
        vm.expectRevert(AvalHook.OnlyOwner.selector);
        hook.requestBondWithdrawal(id, 1);
    }
}
