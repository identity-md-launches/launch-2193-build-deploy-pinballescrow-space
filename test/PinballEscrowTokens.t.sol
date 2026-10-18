// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase, PinballEscrow, MockToken} from "./helpers/EscrowTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PinballEscrowTokensTest is EscrowTestBase {
    function test_MissingAllowanceRollsBackOpenAndJoin() public {
        vm.prank(alice);
        MockToken(IMD).approve(address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, 1e18)
        );
        _open(ID, IMD, 1e18);
        _assertState(ID, PinballEscrow.State.None);
        assertEq(MockToken(IMD).balanceOf(alice), START_BALANCE);
        vm.prank(alice);
        MockToken(IMD).approve(address(escrow), 1e18);
        _open(ID, IMD, 1e18);
        vm.prank(bob);
        MockToken(IMD).approve(address(escrow), 1e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 1e18 - 1, 1e18)
        );
        _join(ID);
        _assertState(ID, PinballEscrow.State.Open);
        assertEq(escrow.matches(ID).playerB, address(0));
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 1e18);
        vm.prank(bob);
        MockToken(IMD).approve(address(escrow), 1e18);
        _join(ID);
    }

    function test_InsufficientBalanceDoesNotReserveAnIdOrPlayerSlot() public {
        address emptyPlayer = makeAddr("empty player");
        vm.startPrank(emptyPlayer);
        MockToken(IMD).approve(address(escrow), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, emptyPlayer, 0, 1e18));
        escrow.open(ID, IMD, 1e18);
        vm.stopPrank();
        _assertState(ID, PinballEscrow.State.None);
        _open(ID, IMD, 1e18);
        vm.prank(emptyPlayer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, emptyPlayer, 0, 1e18));
        escrow.join(ID);
        _join(ID);
        assertEq(escrow.matches(ID).playerB, bob);
    }

    function test_InexactDepositsRollbackStateBalancesAndAllowances() public {
        MockToken token = MockToken(IMD);
        for (uint256 i = 1; i <= 2; ++i) {
            token.setDepositMode(MockToken.DepositMode(i));
            vm.expectRevert(PinballEscrow.IncorrectDeposit.selector);
            _open(ID, IMD, 5e18);
            _assertState(ID, PinballEscrow.State.None);
            assertEq(token.balanceOf(alice), START_BALANCE);
            assertEq(token.allowance(alice, address(escrow)), START_BALANCE);
            assertEq(token.balanceOf(address(escrow)), 0);
        }
        token.setDepositMode(MockToken.DepositMode.Exact);
        _open(ID, IMD, 5e18);
        for (uint256 i = 1; i <= 2; ++i) {
            token.setDepositMode(MockToken.DepositMode(i));
            vm.expectRevert(PinballEscrow.IncorrectDeposit.selector);
            _join(ID);
            _assertState(ID, PinballEscrow.State.Open);
            assertEq(token.balanceOf(bob), START_BALANCE);
            assertEq(token.allowance(bob, address(escrow)), START_BALANCE);
            assertEq(token.balanceOf(address(escrow)), 5e18);
        }
    }

    function test_FalseReturnAndRevertingDepositsCannotCreateOrJoinMatches() public {
        MockToken token = MockToken(IMD);
        token.setDepositMode(MockToken.DepositMode.FalseReturn);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _open(ID, IMD, 1e18);
        token.setDepositMode(MockToken.DepositMode.Revert);
        vm.expectRevert("mock deposit failed");
        _open(ID, IMD, 1e18);
        token.setDepositMode(MockToken.DepositMode.Exact);
        _open(ID, IMD, 1e18);
        token.setDepositMode(MockToken.DepositMode.FalseReturn);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        _join(ID);
        token.setDepositMode(MockToken.DepositMode.Revert);
        vm.expectRevert("mock deposit failed");
        _join(ID);
        _assertState(ID, PinballEscrow.State.Open);
    }

    function test_MissingTokenCodeFailsOnUseAndLeavesMatchUncreated() public {
        vm.etch(IMD, "");
        vm.expectRevert();
        _open(ID, IMD, 1e18);
        _assertState(ID, PinballEscrow.State.None);
    }

    function test_SafeERC20SupportsTokensWithoutReturnValues() public {
        MockToken token = MockToken(IMD);
        token.setDepositMode(MockToken.DepositMode.NoReturn);
        token.setNoTransferReturn(true);
        _openJoined(ID, IMD, 10e18);
        _settle(ID, alice, false);
        assertEq(token.balanceOf(alice), START_BALANCE + 9e18);
        assertEq(token.balanceOf(SPLITTER), 1e18);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_WinnerTransferFailureIsAtomicAndRetryable() public {
        _openJoined(ID, IMD, 10e18);
        MockToken token = MockToken(IMD);
        token.setBlockedRecipient(bob);
        bytes memory signature = _signature(ID, bob, false, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        escrow.settle(ID, bob, false, vm.getBlockTimestamp(), signature);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(token.balanceOf(address(escrow)), 20e18);
        assertEq(token.balanceOf(bob), START_BALANCE - 10e18);
        assertEq(token.balanceOf(SPLITTER), 0);
        token.setBlockedRecipient(address(0));
        escrow.settle(ID, bob, false, vm.getBlockTimestamp(), signature);
    }

    function test_FeeTransferFailureAlsoRollsBackWinnerPayment() public {
        _openJoined(ID, IMD, 25e18);
        MockToken token = MockToken(IMD);
        token.setBlockedRecipient(SPLITTER);
        bytes memory signature = _signature(ID, alice, false, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(token.balanceOf(alice), START_BALANCE - 25e18);
        assertEq(token.balanceOf(address(escrow)), 50e18);
        assertEq(token.balanceOf(SPLITTER), 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        escrow.refund(ID);
        assertEq(token.balanceOf(alice), START_BALANCE);
    }

    function test_DrawSecondTransferFailureAlsoRollsBackFirstRefund() public {
        _openJoined(ID, IMD, 5e18);
        MockToken token = MockToken(IMD);
        token.setBlockedRecipient(bob);
        bytes memory signature = _signature(ID, address(0), true, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        escrow.settle(ID, address(0), true, vm.getBlockTimestamp(), signature);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(token.balanceOf(alice), START_BALANCE - 5e18);
        assertEq(token.balanceOf(address(escrow)), 10e18);
        token.setBlockedRecipient(address(0));
        escrow.settle(ID, address(0), true, vm.getBlockTimestamp(), signature);
    }

    function test_RefundFailureIsAtomicAndDoesNotBlockUnrelatedMatches() public {
        bytes32 otherId = keccak256("unaffected match");
        _openJoined(ID, IMD, 10e18);
        vm.prank(charlie);
        escrow.open(otherId, IMD, 1e18);
        MockToken token = MockToken(IMD);
        token.setBlockedRecipient(bob);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        escrow.refund(ID);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(token.balanceOf(alice), START_BALANCE - 10e18);
        assertEq(token.balanceOf(address(escrow)), 21e18);
        escrow.refund(otherId);
        assertEq(token.balanceOf(charlie), START_BALANCE);
        token.setBlockedRecipient(address(0));
        escrow.refund(ID);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_UnjoinedRefundFailureCanBeRetried() public {
        _open(ID, IMD, 1e18);
        MockToken(IMD).setBlockedRecipient(alice);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, IMD));
        escrow.refund(ID);
        _assertState(ID, PinballEscrow.State.Open);
        MockToken(IMD).setBlockedRecipient(address(0));
        escrow.refund(ID);
    }

    function test_ReentrancyDuringOpenAndJoinIsRejectedWithEffectsAlreadyApplied() public {
        MockToken token = MockToken(IMD);
        token.configureCallback(escrow, abi.encodeCall(escrow.join, (ID)), ID, true, false);
        _open(ID, IMD, 1e18);
        _assertBlockedCallback(token, PinballEscrow.State.Open);
        token.configureCallback(escrow, abi.encodeCall(escrow.refund, (ID)), ID, true, false);
        _join(ID);
        _assertBlockedCallback(token, PinballEscrow.State.Joined);
        assertEq(token.balanceOf(address(escrow)), 2e18);
        assertEq(escrow.matches(ID).playerB, bob);
    }

    function test_ReentrancyDuringSettlementCannotSettleTwiceOrOpenAnotherMatch() public {
        _openJoined(ID, IMD, 1e18);
        MockToken token = MockToken(IMD);
        bytes memory signature = _signature(ID, alice, false, vm.getBlockTimestamp());
        token.configureCallback(
            escrow,
            abi.encodeCall(escrow.settle, (ID, alice, false, vm.getBlockTimestamp(), signature)),
            ID,
            false,
            true
        );
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
        _assertBlockedCallback(token, PinballEscrow.State.Settled);
        bytes32 otherId = keccak256("second match");
        _openJoined(otherId, IMD, 5e18);
        token.configureCallback(
            escrow, abi.encodeCall(escrow.open, (keccak256("reentered open"), IMD, 1e18)), otherId, false, true
        );
        _settle(otherId, bob, false);
        _assertBlockedCallback(token, PinballEscrow.State.Settled);
        assertEq(token.balanceOf(SPLITTER), 0.6e18);
        _assertState(keccak256("reentered open"), PinballEscrow.State.None);
    }

    function test_ReentrancyDuringRefundCannotRefundAgain() public {
        _openJoined(ID, IMD, 25e18);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        MockToken token = MockToken(IMD);
        token.configureCallback(escrow, abi.encodeCall(escrow.refund, (ID)), ID, false, true);
        escrow.refund(ID);
        _assertBlockedCallback(token, PinballEscrow.State.Refunded);
        assertEq(token.balanceOf(alice), START_BALANCE);
        assertEq(token.balanceOf(bob), START_BALANCE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReentrancyCannotMoveAnotherMatchsDeposits() public {
        bytes32 otherId = keccak256("refundable match");
        _open(otherId, IMD, 25e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _openJoined(ID, IMD, 1e18);
        MockToken token = MockToken(IMD);
        token.configureCallback(escrow, abi.encodeCall(escrow.refund, (otherId)), ID, false, true);
        _settle(ID, bob, false);
        _assertBlockedCallback(token, PinballEscrow.State.Settled);
        _assertState(otherId, PinballEscrow.State.Open);
        assertEq(token.balanceOf(address(escrow)), 25e18);
        escrow.refund(otherId);
    }

    function _assertBlockedCallback(MockToken token, PinballEscrow.State expectedState) private view {
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(uint256(token.observedState()), uint256(expectedState));
    }
}
