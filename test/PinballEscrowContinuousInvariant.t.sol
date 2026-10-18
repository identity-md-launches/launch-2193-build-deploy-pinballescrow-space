// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase, MockToken} from "./helpers/EscrowTestBase.sol";
import {ContinuousEscrowHandler} from "./helpers/ContinuousEscrowHandler.sol";

contract PinballEscrowContinuousInvariantTest is EscrowTestBase {
    ContinuousEscrowHandler private handler;
    uint256 private constant EXTRA_BALANCE = 10_000_000_000e18;

    function setUp() public override {
        super.setUp();
        address[3] memory actors = [alice, bob, charlie];
        for (uint256 t; t < 2; ++t) {
            MockToken coin = MockToken(t == 0 ? IMD : SHIFT);
            for (uint256 a; a < actors.length; ++a) {
                coin.mint(actors[a], EXTRA_BALANCE);
                vm.prank(actors[a]);
                coin.approve(address(escrow), type(uint256).max);
            }
        }
        handler = new ContinuousEscrowHandler(escrow, actors, START_BALANCE + EXTRA_BALANCE);
        for (uint8 i; i < 6; ++i) {
            handler.progress(i, i % 2 == 1, i, i, 0);
            if (i < 3) handler.progress(i, false, 0, i + 1, 0);
        }

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ContinuousEscrowHandler.progress.selector;
        selectors[1] = ContinuousEscrowHandler.rejectDeposit.selector;
        selectors[2] = ContinuousEscrowHandler.failPaymentThenRetry.selector;
        selectors[3] = ContinuousEscrowHandler.advanceTime.selector;
        selectors[4] = ContinuousEscrowHandler.administer.selector;
        selectors[5] = ContinuousEscrowHandler.donate.selector;
        selectors[6] = ContinuousEscrowHandler.replayFinished.selector;
        selectors[7] = ContinuousEscrowHandler.progressInvite.selector;
        selectors[8] = ContinuousEscrowHandler.intrude.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ContinuousCustodyAndRecovery() public view {
        handler.checkAccounting();
    }

    function afterInvariant() public {
        handler.drain();
    }

    /// @dev Deterministic witness that successful exits, fault paths and recycled slots are reachable.
    function test_HandlerExercisesFailuresFreshMatchesAndEveryExit() public {
        handler.checkAccounting();
        // Slots 0, 1 and 2 were joined in setUp; cover wins, draws, and payout retries.
        handler.progress(0, false, 0, 0, 0);
        handler.progress(1, false, 0, 0, 2);
        handler.failPaymentThenRetry(2, 1, true);
        // Slot 3 is still open: test every failed-deposit mode on join and on a new open.
        for (uint8 fault; fault < 5; ++fault) {
            handler.rejectDeposit(3, true, 3, fault, 1);
            handler.rejectDeposit(0, false, 3, fault, 2);
        }
        // A live open can join while paused; signer rotation also leaves existing exits usable.
        handler.administer(true, true);
        handler.progress(3, false, 0, 2, 0);
        handler.failPaymentThenRetry(3, 2, true);
        handler.replayFinished(0);
        handler.administer(false, false);
        handler.progress(0, true, 3, 2, 0);
        handler.progress(0, false, 0, 1, 0);
        handler.progress(0, false, 0, 1, 1);
        handler.advanceTime(4); // Unjoined refunds at exactly one hour.
        handler.failPaymentThenRetry(4, 0, false);
        handler.replayFinished(4);
        handler.donate(true, 0, 1);
        handler.checkAccounting();
        assertEq(handler.opens(), 7, "finished slot must accept a fresh ID");
        assertEq(handler.joins(), 5);
        assertEq(handler.wins(), 3);
        assertEq(handler.draws(), 2);
        assertEq(handler.failedDeposits(), 10);
        assertEq(handler.failedPayments(), 3);
        assertEq(handler.rejectedReplays(), 2);
        assertEq(handler.refunds(), 1);
        handler.drain();
        assertEq(handler.refunds(), 2);
    }

    /// @dev Deterministic witness that invite-only opens, checked joins and rejected intrusions are reachable.
    function test_HandlerExercisesInvitesCheckedJoinsAndIntrusions() public {
        // Slots 0-2 are joined, 3-5 open: settle slot 0 so progressInvite opens a fresh invite there.
        handler.progress(0, false, 0, 0, 0);
        handler.progressInvite(0, true, 2, 1, 2);
        for (uint8 mismatch; mismatch < 3; ++mismatch) {
            handler.intrude(0, mismatch, mismatch);
            handler.intrude(3, mismatch, mismatch);
        }
        // The invitee's deposit can fail and roll back without losing the reserved slot.
        handler.rejectDeposit(0, false, 0, 4, 0);
        // Joins stay open while paused; invite-only opens are paused like public ones.
        handler.administer(true, false);
        handler.progressInvite(0, false, 0, 0, 0);
        handler.progressInvite(3, false, 0, 1, 0);
        handler.progressInvite(0, false, 0, 0, 1);
        handler.progressInvite(0, false, 0, 0, 0);
        handler.replayFinished(0);
        handler.administer(false, true);
        handler.progressInvite(0, false, 3, 2, 1);
        handler.advanceTime(4);
        handler.intrude(0, 0, 0); // Past the join window: no longer a live open.
        handler.progressInvite(0, false, 0, 0, 2); // Unjoined invite refunds player A.
        handler.checkAccounting();
        assertEq(handler.invites(), 2);
        assertEq(handler.checkedJoins(), 2);
        assertEq(handler.rejectedIntrusions(), 6);
        assertEq(handler.failedDeposits(), 1);
        handler.drain();
    }
}
