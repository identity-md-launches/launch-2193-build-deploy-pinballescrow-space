// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase, PinballEscrow, MockToken} from "./helpers/EscrowTestBase.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract PinballFactoryProbe {
    function deploy(address owner_, address initialSigner, bytes32 salt) external returns (PinballEscrow) {
        return new PinballEscrow{salt: salt}(owner_, initialSigner);
    }
}

contract PinballEscrowTest is EscrowTestBase {
    event Opened(bytes32 indexed matchId, address indexed token, uint256 stake, address indexed playerA);
    event Invited(bytes32 indexed matchId, address indexed invitee);
    event Joined(bytes32 indexed matchId, address indexed playerB);
    event Settled(bytes32 indexed matchId, address indexed winner, bool draw, uint256 payout, uint256 fee);
    event Refunded(bytes32 indexed matchId);
    event SignerUpdated(address indexed previousSigner, address indexed newSigner);
    event Paused(address account);
    event Unpaused(address account);

    function test_DeploymentOnEmptyChainHasFixedConfiguration() public {
        vm.etch(IMD, "");
        vm.etch(SHIFT, "");
        vm.etch(OWNER, "");
        PinballFactoryProbe factory = new PinballFactoryProbe();
        bytes32 salt = keccak256("factory launch rehearsal");
        vm.expectEmit(true, true, false, true);
        emit SignerUpdated(address(0), OWNER);
        PinballEscrow deployed = factory.deploy(OWNER, OWNER, salt);
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(PinballEscrow).creationCode, abi.encode(OWNER, OWNER)));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, initCodeHash)))));
        assertEq(address(deployed), predicted);
        assertEq(deployed.owner(), OWNER);
        assertEq(deployed.signer(), OWNER);
        assertEq(deployed.IMD(), IMD);
        assertEq(deployed.SHIFT(), SHIFT);
        assertEq(deployed.FEE_RECIPIENT(), SPLITTER);
        assertEq(deployed.FEE_BPS(), 500);
        assertEq(deployed.BPS_DENOMINATOR(), 10_000);
        assertEq(deployed.JOIN_WINDOW(), 1 hours);
        assertEq(deployed.SETTLEMENT_WINDOW(), 24 hours);
        assertFalse(deployed.paused());
        assertNotEq(deployed.owner(), address(this));
        assertNotEq(deployed.owner(), address(factory));
        vm.prank(address(factory));
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        deployed.pause();
    }

    /// @dev The launch fills the owner argument; owner() must follow it, never the factory or the origin.
    function testFuzz_OwnerFollowsConstructorArgumentNotDeployerOrOrigin(address launchOwner, address origin) public {
        vm.assume(launchOwner != address(0) && origin != address(0));
        vm.assume(launchOwner != address(vm) && origin != address(vm) && uint160(origin) > 0xff);
        PinballFactoryProbe factory = new PinballFactoryProbe();
        vm.assume(launchOwner != address(factory) && launchOwner != origin);
        vm.prank(origin, origin);
        PinballEscrow deployed = factory.deploy(launchOwner, launchOwner, keccak256("owner probe"));
        assertEq(deployed.owner(), launchOwner);
        assertEq(deployed.signer(), launchOwner);
        assertNotEq(deployed.owner(), address(factory));
        assertNotEq(deployed.owner(), origin);
        vm.prank(address(factory));
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        deployed.setSigner(address(factory));
        vm.prank(origin);
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        deployed.pause();
        vm.prank(launchOwner);
        deployed.pause();
        assertTrue(deployed.paused());
    }

    function test_ConstructorRejectsZeroOwnerOrZeroInitialSigner() public {
        vm.expectRevert(PinballEscrow.InvalidOwner.selector);
        new PinballEscrow(address(0), OWNER);
        vm.expectRevert(PinballEscrow.InvalidSigner.selector);
        new PinballEscrow(OWNER, address(0));
    }

    function test_RuntimeMeetsProtectedOpcodeAndSizeFloor() public view {
        bytes memory code = address(escrow).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }

    function test_OpenAndJoinRecordExactDepositsAndEvents() public {
        uint256 stake = 5e18;
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Opened(ID, IMD, stake, alice);
        _open(ID, IMD, stake);
        PinballEscrow.Match memory game = escrow.matches(ID);
        assertEq(game.token, IMD);
        assertEq(game.stake, stake);
        assertEq(game.playerA, alice);
        assertEq(game.playerB, address(0));
        assertEq(game.openedAt, vm.getBlockTimestamp());
        assertEq(game.joinedAt, 0);
        _assertState(ID, PinballEscrow.State.Open);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), stake);
        assertEq(MockToken(IMD).balanceOf(alice), START_BALANCE - stake);
        vm.warp(vm.getBlockTimestamp() + 37);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Joined(ID, bob);
        _join(ID);
        game = escrow.matches(ID);
        assertEq(game.playerB, bob);
        assertEq(game.joinedAt, vm.getBlockTimestamp());
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), stake * 2);
        assertEq(MockToken(IMD).balanceOf(bob), START_BALANCE - stake);
    }

    function test_AllTiersBothTokensBothWinnersAndDraw() public {
        for (uint256 t; t < 2; ++t) {
            address token = t == 0 ? IMD : SHIFT;
            for (uint256 tier; tier < 4; ++tier) {
                for (uint256 outcome; outcome < 3; ++outcome) {
                    _checkFlow(keccak256(abi.encode(t, tier, outcome)), token, _stake(t == 1, tier), outcome);
                }
            }
        }
    }

    function testFuzz_AllowedStakesConserveFunds(bool shift, uint8 tier, uint8 outcome, bytes32 matchId) public {
        _checkFlow(matchId, shift ? SHIFT : IMD, _stake(shift, tier), outcome % 3);
    }

    function _checkFlow(bytes32 matchId, address token, uint256 stake, uint256 outcome) private {
        MockToken coin = MockToken(token);
        uint256[5] memory beforeBalances = [
            coin.balanceOf(alice),
            coin.balanceOf(bob),
            coin.balanceOf(SPLITTER),
            coin.balanceOf(relayer),
            coin.balanceOf(OWNER)
        ];
        _openJoined(matchId, token, stake);
        bool draw = outcome == 2;
        address winner = draw ? address(0) : outcome == 0 ? alice : bob;
        uint256 fee = draw ? 0 : stake / 10;
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Settled(matchId, winner, draw, stake * 2 - fee, fee);
        _settle(matchId, winner, draw);
        _assertState(matchId, PinballEscrow.State.Settled);
        assertEq(
            coin.balanceOf(alice),
            draw ? beforeBalances[0] : beforeBalances[0] - stake + (winner == alice ? stake * 2 - fee : 0)
        );
        assertEq(
            coin.balanceOf(bob),
            draw ? beforeBalances[1] : beforeBalances[1] - stake + (winner == bob ? stake * 2 - fee : 0)
        );
        assertEq(coin.balanceOf(SPLITTER), beforeBalances[2] + fee);
        assertEq(coin.balanceOf(relayer), beforeBalances[3]);
        assertEq(coin.balanceOf(OWNER), beforeBalances[4]);
        assertEq(coin.balanceOf(address(escrow)), 0);
    }

    function testFuzz_RejectsWrongStake(bool shift, uint256 stake) public {
        address token = shift ? SHIFT : IMD;
        bool allowed;
        for (uint256 i; i < 4; ++i) {
            allowed = allowed || stake == _stake(shift, i);
        }
        vm.assume(!allowed);
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, token, stake);
        _assertState(ID, PinballEscrow.State.None);
        assertEq(MockToken(token).balanceOf(address(escrow)), 0);
    }

    function test_RejectsWholeTokenAmountsAndOtherTokenTiers() public {
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, IMD, 1);
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, SHIFT, 100_000);
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, IMD, 100_000e18);
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, SHIFT, 1e18);
    }

    function testFuzz_RejectsUnsupportedTokens(address token) public {
        vm.assume(token != IMD && token != SHIFT);
        assertFalse(escrow.isAllowedStake(token, 1e18));
        vm.expectRevert(PinballEscrow.UnsupportedToken.selector);
        _open(ID, token, 1e18);
    }

    function test_RejectsMissingMatches() public {
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.join(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.refund(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), "");
    }

    function test_RejectsDuplicateOpenSelfJoinAndThirdPlayer() public {
        _open(ID, IMD, 1e18);
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        _open(ID, SHIFT, 100_000e18);
        vm.prank(alice);
        vm.expectRevert(PinballEscrow.CannotJoinOwnMatch.selector);
        escrow.join(ID);
        _join(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        _join(ID);
        vm.prank(charlie);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.join(ID);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 2e18);
        assertEq(MockToken(IMD).balanceOf(charlie), START_BALANCE);
    }

    /// @dev Finding cc82eb10, squat variant: a front-run open with another tier must not bind the checked joiner.
    function test_SquattedIdCannotChangeACheckedJoinersTokenOrStake() public {
        address mallory = charlie;
        vm.prank(mallory);
        escrow.open(ID, SHIFT, 5_000_000e18);
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        _open(ID, IMD, 1e18);
        vm.prank(bob);
        vm.expectRevert(PinballEscrow.MatchMismatch.selector);
        escrow.joinChecked(ID, IMD, 1e18, alice);
        assertEq(MockToken(IMD).balanceOf(bob), START_BALANCE);
        assertEq(MockToken(SHIFT).balanceOf(bob), START_BALANCE);
        assertEq(escrow.matches(ID).playerB, address(0));
        _assertState(ID, PinballEscrow.State.Open);
        // The squatter only locks their own stake and recovers it after the join window.
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        escrow.refund(ID);
        assertEq(MockToken(SHIFT).balanceOf(mallory), START_BALANCE);
    }

    function test_JoinCheckedRejectsEveryMismatchAndAcceptsTheExactMatch() public {
        _open(ID, IMD, 5e18);
        vm.startPrank(bob);
        vm.expectRevert(PinballEscrow.MatchMismatch.selector);
        escrow.joinChecked(ID, SHIFT, 5e18, alice);
        vm.expectRevert(PinballEscrow.MatchMismatch.selector);
        escrow.joinChecked(ID, IMD, 1e18, alice);
        vm.expectRevert(PinballEscrow.MatchMismatch.selector);
        escrow.joinChecked(ID, IMD, 5e18, charlie);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.joinChecked(keccak256("never opened"), IMD, 5e18, alice);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(PinballEscrow.CannotJoinOwnMatch.selector);
        escrow.joinChecked(ID, IMD, 5e18, alice);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Joined(ID, bob);
        vm.prank(bob);
        escrow.joinChecked(ID, IMD, 5e18, alice);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(escrow.matches(ID).playerB, bob);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 10e18);
        vm.prank(charlie);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.joinChecked(ID, IMD, 5e18, alice);
        _settle(ID, bob, false);
    }

    function testFuzz_JoinCheckedBindsOnlyTheExactParameters(
        bool shift,
        uint8 tier,
        address token,
        uint256 stake,
        address playerA
    ) public {
        address realToken = shift ? SHIFT : IMD;
        uint256 realStake = _stake(shift, tier);
        _open(ID, realToken, realStake);
        bool exact = token == realToken && stake == realStake && playerA == alice;
        vm.prank(bob);
        if (!exact) vm.expectRevert(PinballEscrow.MatchMismatch.selector);
        escrow.joinChecked(ID, token, stake, playerA);
        assertEq(MockToken(realToken).balanceOf(bob), exact ? START_BALANCE - realStake : START_BALANCE);
        assertEq(escrow.matches(ID).playerB, exact ? bob : address(0));
    }

    /// @dev Finding cc82eb10, slot-snipe variant: an invite-only open keeps the arranged opponent.
    function test_InviteOnlyMatchRejectsSlotSnipersAndSettlesForTheInvitee() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit Opened(ID, IMD, 25e18, alice);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit Invited(ID, bob);
        vm.prank(alice);
        escrow.openInvite(ID, IMD, 25e18, bob);
        PinballEscrow.Match memory game = escrow.matches(ID);
        assertEq(game.invitee, bob);
        assertEq(game.playerA, alice);
        _assertState(ID, PinballEscrow.State.Open);
        vm.startPrank(charlie);
        vm.expectRevert(PinballEscrow.NotInvited.selector);
        escrow.join(ID);
        vm.expectRevert(PinballEscrow.NotInvited.selector);
        escrow.joinChecked(ID, IMD, 25e18, alice);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(PinballEscrow.CannotJoinOwnMatch.selector);
        escrow.join(ID);
        assertEq(escrow.matches(ID).playerB, address(0));
        assertEq(MockToken(IMD).balanceOf(charlie), START_BALANCE);
        vm.prank(bob);
        escrow.joinChecked(ID, IMD, 25e18, alice);
        assertEq(escrow.matches(ID).playerB, bob);
        _settle(ID, bob, false);
        assertEq(MockToken(IMD).balanceOf(bob), START_BALANCE + 22.5e18);
        assertEq(MockToken(IMD).balanceOf(SPLITTER), 2.5e18);
    }

    function test_InviteeMayUsePlainJoinAndOpenMatchesStayPublic() public {
        bytes32 publicId = keccak256("public match");
        vm.prank(alice);
        escrow.openInvite(ID, SHIFT, 100_000e18, bob);
        _open(publicId, SHIFT, 100_000e18);
        assertEq(escrow.matches(publicId).invitee, address(0));
        _join(ID);
        vm.prank(charlie);
        escrow.join(publicId);
        assertEq(escrow.matches(ID).playerB, bob);
        assertEq(escrow.matches(publicId).playerB, charlie);
    }

    function test_OpenInviteRejectsZeroAndSelfInviteeAndUsedIds() public {
        vm.startPrank(alice);
        vm.expectRevert(PinballEscrow.InvalidInvitee.selector);
        escrow.openInvite(ID, IMD, 1e18, address(0));
        vm.expectRevert(PinballEscrow.InvalidInvitee.selector);
        escrow.openInvite(ID, IMD, 1e18, alice);
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        escrow.openInvite(ID, IMD, 2e18, bob);
        vm.expectRevert(PinballEscrow.UnsupportedToken.selector);
        escrow.openInvite(ID, address(this), 1e18, bob);
        escrow.openInvite(ID, IMD, 1e18, bob);
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        escrow.openInvite(ID, IMD, 1e18, charlie);
        vm.stopPrank();
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        _open(ID, IMD, 1e18);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 1e18);
    }

    function test_InviteOnlyOpenRefundsAndPausesLikeAPublicOpen() public {
        vm.prank(alice);
        escrow.openInvite(ID, IMD, 10e18, bob);
        vm.prank(OWNER);
        escrow.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.openInvite(keccak256("paused invite"), IMD, 10e18, bob);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(bob);
        vm.expectRevert(PinballEscrow.JoinWindowClosed.selector);
        escrow.join(ID);
        escrow.refund(ID);
        _assertState(ID, PinballEscrow.State.Refunded);
        assertEq(MockToken(IMD).balanceOf(alice), START_BALANCE);
    }

    function test_CannotSettleUnjoinedMatch() public {
        _open(ID, IMD, 1e18);
        bytes memory signature = _signature(ID, alice, false, vm.getBlockTimestamp());
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
    }

    function testFuzz_BothRefundPathsBothTokens(bool shift, bool joined, uint8 tier) public {
        address token = shift ? SHIFT : IMD;
        uint256 stake = _stake(shift, tier);
        _open(ID, token, stake);
        uint256 eligibleAt = vm.getBlockTimestamp() + 1 hours;
        if (joined) {
            vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
            _join(ID);
            eligibleAt = vm.getBlockTimestamp() + 24 hours;
        }
        vm.warp(eligibleAt - 1);
        vm.expectRevert(PinballEscrow.RefundNotReady.selector);
        escrow.refund(ID);
        vm.warp(eligibleAt);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit Refunded(ID);
        vm.prank(relayer);
        escrow.refund(ID);
        _assertState(ID, PinballEscrow.State.Refunded);
        assertEq(MockToken(token).balanceOf(alice), START_BALANCE);
        assertEq(MockToken(token).balanceOf(bob), START_BALANCE);
        assertEq(MockToken(token).balanceOf(SPLITTER), 0);
        assertEq(MockToken(token).balanceOf(address(escrow)), 0);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.refund(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.join(ID);
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        _open(ID, token, stake);
    }

    function test_JoinClosesAtExactOneHourBoundary() public {
        _open(ID, IMD, 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(PinballEscrow.JoinWindowClosed.selector);
        _join(ID);
        escrow.refund(ID);
    }

    function test_SettlementWindowStartsAtJoinAndClosesAtExactBoundary() public {
        _open(ID, IMD, 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        _join(ID);
        uint256 joinedAt = vm.getBlockTimestamp();
        vm.warp(joinedAt + 24 hours - 1);
        vm.expectRevert(PinballEscrow.RefundNotReady.selector);
        escrow.refund(ID);
        bytes memory signature = _signature(ID, bob, false, vm.getBlockTimestamp() + 1 days);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        vm.warp(joinedAt + 24 hours);
        vm.expectRevert(PinballEscrow.SettlementWindowClosed.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        escrow.refund(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, bob, false, deadline, signature);
    }

    function test_SettlementSucceedsOneSecondBeforeTimeout() public {
        _openJoined(ID, IMD, 25e18);
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        _settle(ID, bob, false);
        _assertState(ID, PinballEscrow.State.Settled);
    }

    function test_SettledIdsCannotReopenRefundOrJoin() public {
        _openJoined(ID, IMD, 1e18);
        _settle(ID, alice, false);
        vm.expectRevert(PinballEscrow.MatchAlreadyExists.selector);
        _open(ID, IMD, 1e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.refund(ID);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        _join(ID);
    }

    function test_PauseOnlyPreventsNewOpensAndUnpauseRestoresThem() public {
        bytes32 refundId = keccak256("refund while paused");
        _open(ID, IMD, 1e18);
        _open(refundId, SHIFT, 500_000e18);
        vm.expectEmit(false, false, false, true, address(escrow));
        emit Paused(OWNER);
        vm.prank(OWNER);
        escrow.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _open(keccak256("paused"), IMD, 1e18);
        _join(ID);
        _settle(ID, bob, false);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        escrow.refund(refundId);
        vm.expectEmit(false, false, false, true, address(escrow));
        emit Unpaused(OWNER);
        vm.prank(OWNER);
        escrow.unpause();
        _open(keccak256("unpaused"), IMD, 1e18);
        assertFalse(escrow.paused());
    }

    function test_JoinedRefundWorksWhilePaused() public {
        _openJoined(ID, SHIFT, 5_000_000e18);
        vm.prank(OWNER);
        escrow.pause();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        escrow.refund(ID);
        assertEq(MockToken(SHIFT).balanceOf(address(escrow)), 0);
    }

    function testFuzz_OnlyOwnerCanAdminister(address caller) public {
        vm.assume(caller != OWNER);
        vm.startPrank(caller);
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        escrow.setSigner(caller);
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        escrow.pause();
        vm.expectRevert(PinballEscrow.Unauthorized.selector);
        escrow.unpause();
        vm.stopPrank();
    }

    function test_SignerAndPauseEventsAndInvalidChanges() public {
        vm.startPrank(OWNER);
        vm.expectRevert(PinballEscrow.InvalidSigner.selector);
        escrow.setSigner(address(0));
        vm.expectEmit(true, true, false, true, address(escrow));
        emit SignerUpdated(resultSigner, charlie);
        escrow.setSigner(charlie);
        assertEq(escrow.signer(), charlie);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        escrow.unpause();
        escrow.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.pause();
        escrow.setSigner(resultSigner);
        vm.stopPrank();
    }

    function test_OwnerHasNoWithdrawalOwnershipTransferOrUpgradeSurface() public {
        _openJoined(ID, IMD, 10e18);
        bytes[8] memory calls = [
            abi.encodeWithSignature("withdraw(address,uint256)", IMD, 20e18),
            abi.encodeWithSignature("sweep(address,address)", IMD, OWNER),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("setFee(uint256)", 0),
            abi.encodeWithSignature("setFeeRecipient(address)", OWNER),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", OWNER, bytes("")),
            abi.encodeWithSignature("setToken(address,bool)", alice, true)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(OWNER);
            (bool ok,) = address(escrow).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 20e18);
        assertEq(escrow.owner(), OWNER);
    }

    function test_ConcurrentMatchesAndDonationsCannotChangeAPot() public {
        bytes32 second = keccak256("second");
        bytes32 third = keccak256("third");
        _openJoined(ID, IMD, 1e18);
        _openJoined(second, IMD, 25e18);
        _openJoined(third, SHIFT, 1_000_000e18);
        vm.prank(charlie);
        MockToken(IMD).transfer(address(escrow), 9e18);
        _settle(ID, alice, false);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 59e18);
        assertEq(MockToken(IMD).balanceOf(SPLITTER), 0.1e18);
        _settle(second, address(0), true);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 9e18);
        _settle(third, bob, false);
        assertEq(MockToken(SHIFT).balanceOf(address(escrow)), 0);
    }

    function test_RejectsNativeEtherAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool sent,) = address(escrow).call{value: 1 ether}("");
        assertFalse(sent);
        (bool unknown,) = address(escrow).call(hex"12345678");
        assertFalse(unknown);
    }
}
