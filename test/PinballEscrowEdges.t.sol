// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase, PinballEscrow, MockToken} from "./helpers/EscrowTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Explicit edge cases complement the existing broad flow and signature suite.
contract PinballEscrowEdgesTest is EscrowTestBase {
    function test_EveryStakeNeighbourAndIntegerExtremeIsRejectedWithoutTakingFunds() public {
        for (uint256 t; t < 2; ++t) {
            address token = t == 0 ? IMD : SHIFT;
            _rejectStake(token, 0);
            _rejectStake(token, 1);
            _rejectStake(token, type(uint256).max);
            for (uint256 tier; tier < 4; ++tier) {
                uint256 stake = _stake(t == 1, tier);
                assertTrue(escrow.isAllowedStake(token, stake));
                _rejectStake(token, stake - 1);
                _rejectStake(token, stake + 1);
                _rejectStake(token, stake / 1e18);
                _rejectStake(token, _stake(t == 0, tier));
            }
            assertEq(MockToken(token).balanceOf(alice), START_BALANCE);
            assertEq(MockToken(token).allowance(alice, address(escrow)), START_BALANCE);
            assertEq(MockToken(token).balanceOf(address(escrow)), 0);
        }
    }

    function _rejectStake(address token, uint256 stake) private {
        assertFalse(escrow.isAllowedStake(token, stake));
        vm.expectRevert(PinballEscrow.InvalidStake.selector);
        _open(ID, token, stake);
        _assertState(ID, PinballEscrow.State.None);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_EntireBalancesAndExactAllowancesCanFundAndExit(
        bool shift,
        uint8 tier,
        uint8 outcomeSeed,
        uint256 joinDelaySeed
    ) public {
        address token = shift ? SHIFT : IMD;
        uint256 stake = _stake(shift, tier);
        uint256 outcome = bound(uint256(outcomeSeed), 0, 4);
        address a = makeAddr("exact balance A");
        address b = makeAddr("exact balance B");
        MockToken coin = MockToken(token);
        coin.mint(a, stake);
        coin.mint(b, stake);
        vm.startPrank(a);
        coin.approve(address(escrow), stake);
        escrow.open(ID, token, stake);
        vm.stopPrank();
        assertEq(coin.balanceOf(a), 0);
        assertEq(coin.allowance(a, address(escrow)), 0);

        if (outcome != 4) {
            vm.warp(vm.getBlockTimestamp() + bound(joinDelaySeed, 0, 1 hours - 1));
            vm.startPrank(b);
            coin.approve(address(escrow), stake);
            escrow.join(ID);
            vm.stopPrank();
            assertEq(coin.balanceOf(b), 0);
            assertEq(coin.allowance(b, address(escrow)), 0);
        }

        if (outcome >= 3) {
            vm.warp(vm.getBlockTimestamp() + (outcome == 4 ? 1 hours : 24 hours));
            vm.prank(relayer);
            escrow.refund(ID);
            _assertState(ID, PinballEscrow.State.Refunded);
        } else {
            address winner = outcome == 2 ? address(0) : outcome == 0 ? a : b;
            _settle(ID, winner, outcome == 2);
            _assertState(ID, PinballEscrow.State.Settled);
        }

        uint256 fee = outcome < 2 ? stake / 10 : 0;
        assertEq(coin.balanceOf(a), outcome >= 2 ? stake : outcome == 0 ? 2 * stake - fee : 0);
        assertEq(coin.balanceOf(b), outcome >= 2 ? stake : outcome == 1 ? 2 * stake - fee : 0);
        assertEq(coin.balanceOf(SPLITTER), fee);
        assertEq(coin.balanceOf(address(escrow)), 0);
        assertEq(coin.balanceOf(relayer), 0);
        assertEq(coin.balanceOf(OWNER), 0);
    }

    function testFuzz_ApprovalForTheOtherTokenCannotFundAJoin(bool shift, uint8 tier) public {
        address token = shift ? SHIFT : IMD;
        address other = shift ? IMD : SHIFT;
        uint256 stake = _stake(shift, tier);
        _open(ID, token, stake);
        vm.prank(bob);
        MockToken(token).approve(address(escrow), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, stake)
        );
        _join(ID);
        _assertState(ID, PinballEscrow.State.Open);
        assertEq(escrow.matches(ID).playerB, address(0));
        assertEq(MockToken(token).balanceOf(bob), START_BALANCE);
        assertEq(MockToken(other).balanceOf(bob), START_BALANCE);
        assertEq(MockToken(other).allowance(bob, address(escrow)), START_BALANCE);
        assertEq(MockToken(other).balanceOf(address(escrow)), 0);
        vm.prank(bob);
        MockToken(token).approve(address(escrow), stake);
        _join(ID);
        assertEq(MockToken(token).allowance(bob, address(escrow)), 0);
        assertEq(MockToken(other).allowance(bob, address(escrow)), START_BALANCE);
    }

    /// @dev Exercises every payment leg and every tier, including the second transfer's rollback.
    function test_AllExitPaymentFailuresBothTokensAreAtomicAndRetryable() public {
        for (uint256 t; t < 2; ++t) {
            for (uint256 tier; tier < 4; ++tier) {
                for (uint256 path; path < 7; ++path) {
                    _checkFailedExit(t == 1, tier, path);
                }
            }
        }
    }

    function _checkFailedExit(bool shift, uint256 tier, uint256 path) private {
        address token = shift ? SHIFT : IMD;
        MockToken coin = MockToken(token);
        bytes32 id = keccak256(abi.encode("atomic exit", shift, tier, path));
        uint256 stake = _stake(shift, tier);
        uint256[3] memory initial = [coin.balanceOf(alice), coin.balanceOf(bob), coin.balanceOf(SPLITTER)];
        _open(id, token, stake);
        bool joined = path != 6;
        if (joined) _join(id);
        bool refunding = path >= 4;
        bool draw = path == 2 || path == 3;
        if (refunding) vm.warp(vm.getBlockTimestamp() + (joined ? 24 hours : 1 hours));
        address recipient = path == 1 ? SPLITTER : (path == 2 || path == 4 || path == 6) ? alice : bob;
        address winner = draw ? address(0) : bob;
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes memory signature = _signature(id, winner, draw, deadline);
        bytes32 matchBefore = keccak256(abi.encode(escrow.matches(id)));
        coin.setBlockedRecipient(recipient);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, token));
        if (refunding) escrow.refund(id);
        else escrow.settle(id, winner, draw, deadline, signature);
        assertEq(keccak256(abi.encode(escrow.matches(id))), matchBefore, "failed exit changed match");
        assertEq(coin.balanceOf(alice), initial[0] - stake, "partial A payment survived revert");
        assertEq(coin.balanceOf(bob), initial[1] - (joined ? stake : 0), "partial B payment survived revert");
        assertEq(coin.balanceOf(SPLITTER), initial[2]);
        assertEq(coin.balanceOf(address(escrow)), stake * (joined ? 2 : 1));

        coin.setBlockedRecipient(address(0));
        vm.prank(relayer);
        if (refunding) escrow.refund(id);
        else escrow.settle(id, winner, draw, deadline, signature);
        uint256 fee = refunding || draw ? 0 : stake / 10;
        assertEq(coin.balanceOf(alice), fee == 0 ? initial[0] : initial[0] - stake);
        assertEq(coin.balanceOf(bob), fee == 0 ? initial[1] : initial[1] + stake - fee);
        assertEq(coin.balanceOf(SPLITTER), initial[2] + fee);
        assertEq(coin.balanceOf(address(escrow)), 0);
        assertEq(coin.balanceOf(relayer), 0);
    }

    function testFuzz_MalformedSignatureLengthsCannotReleaseAJoinedPot(bytes memory signature, bool shift) public {
        // Every generated value is malformed for the ECDSA bytes interface; never exclude a run.
        if (signature.length == 65) signature = bytes.concat(signature, hex"00");
        _openJoined(ID, shift ? SHIFT : IMD, _stake(shift, 3));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(MockToken(shift ? SHIFT : IMD).balanceOf(address(escrow)), _stake(shift, 3) * 2);
        // A rejected result must not consume the match or lock the reentrancy guard.
        _settle(ID, bob, false);
    }
}
