// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase, PinballEscrow, MockToken} from "./helpers/EscrowTestBase.sol";
import {SignerMock} from "./helpers/SignerMock.sol";

contract PinballEscrowSignaturesTest is EscrowTestBase {
    function test_DomainAndResultDigestMatchIndependentEncoding() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = escrow.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "SpacePinball");
        assertEq(version, "1");
        assertEq(chainId, 1);
        assertEq(verifyingContract, address(escrow));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(escrow.hashResult(ID, alice, false, 1_500_000), _digest(escrow, 1, ID, alice, false, 1_500_000));
    }

    function test_WrongSignerIsRejected() public {
        _openJoined(ID, IMD, 1e18);
        bytes memory signature = _signDigest(OTHER_KEY, _digest(escrow, 1, ID, alice, false, vm.getBlockTimestamp()));
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
        _assertState(ID, PinballEscrow.State.Joined);
        assertEq(MockToken(IMD).balanceOf(address(escrow)), 2e18);
    }

    function test_ExpiredSignatureRejectedButExactDeadlineAccepted() public {
        _openJoined(ID, IMD, 5e18);
        uint256 deadline = vm.getBlockTimestamp() + 60;
        bytes memory signature = _signature(ID, bob, false, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(PinballEscrow.SignatureExpired.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        bytes memory valid = _signature(ID, bob, false, vm.getBlockTimestamp());
        escrow.settle(ID, bob, false, vm.getBlockTimestamp(), valid);
    }

    function test_ReplayAndFreshConflictingResultCannotDoubleSettle() public {
        _openJoined(ID, SHIFT, 500_000e18);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory signature = _signature(ID, alice, false, deadline);
        bytes memory conflicting = _signature(ID, bob, false, deadline);
        escrow.settle(ID, alice, false, deadline, signature);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, alice, false, deadline, signature);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, bob, false, deadline, conflicting);
        assertEq(MockToken(SHIFT).balanceOf(SPLITTER), 50_000e18);
    }

    function test_DrawCannotBeSettledAgain() public {
        _openJoined(ID, IMD, 25e18);
        _settle(ID, address(0), true);
        bytes memory signature = _signature(ID, alice, false, vm.getBlockTimestamp());
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
        assertEq(MockToken(IMD).balanceOf(alice), START_BALANCE);
    }

    function test_MatchIdWinnerDrawAndDeadlineAreAllBound() public {
        bytes32 otherId = keccak256("another joined match");
        _openJoined(ID, IMD, 10e18);
        _openJoined(otherId, IMD, 10e18);
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes memory signature = _signature(ID, alice, false, deadline);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(otherId, alice, false, deadline, signature);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, address(0), true, deadline, signature);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, alice, false, deadline + 1, signature);
        bytes memory wrongDrawBit = _signature(ID, alice, true, deadline);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, alice, false, deadline, wrongDrawBit);
        escrow.settle(ID, alice, false, deadline, signature);
        _settle(otherId, bob, false);
    }

    function testFuzz_SignerCannotAwardPotToAnOutsider(address outsider) public {
        vm.assume(outsider != alice && outsider != bob);
        _openJoined(ID, IMD, 1e18);
        bytes memory signature = _signature(ID, outsider, false, vm.getBlockTimestamp());
        vm.expectRevert(PinballEscrow.InvalidWinner.selector);
        escrow.settle(ID, outsider, false, vm.getBlockTimestamp(), signature);
    }

    function test_DrawRequiresCanonicalNoWinner() public {
        _openJoined(ID, IMD, 1e18);
        bytes memory signature = _signature(ID, alice, true, vm.getBlockTimestamp());
        vm.expectRevert(PinballEscrow.InvalidWinner.selector);
        escrow.settle(ID, alice, true, vm.getBlockTimestamp(), signature);
        _settle(ID, address(0), true);
    }

    function test_CannotReplayAcrossContracts() public {
        PinballEscrow other = new PinballEscrow(OWNER, OWNER);
        vm.prank(OWNER);
        other.setSigner(resultSigner);
        _openJoined(ID, IMD, 1e18);
        vm.startPrank(alice);
        MockToken(IMD).approve(address(other), 1e18);
        other.open(ID, IMD, 1e18);
        vm.stopPrank();
        vm.startPrank(bob);
        MockToken(IMD).approve(address(other), 1e18);
        other.join(ID);
        vm.stopPrank();
        bytes memory signature = _signature(ID, alice, false, vm.getBlockTimestamp());
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        other.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
        bytes memory correct = _signDigest(SIGNER_KEY, _digest(other, 1, ID, bob, false, vm.getBlockTimestamp()));
        other.settle(ID, bob, false, vm.getBlockTimestamp(), correct);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), signature);
    }

    function test_ChainIdChangeRejectsOldSignatureAndAcceptsNewDomain() public {
        _openJoined(ID, IMD, 1e18);
        bytes memory oldSignature = _signature(ID, alice, false, vm.getBlockTimestamp());
        vm.chainId(2);
        assertEq(
            escrow.hashResult(ID, alice, false, vm.getBlockTimestamp()),
            _digest(escrow, 2, ID, alice, false, vm.getBlockTimestamp())
        );
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), oldSignature);
        bytes memory newSignature =
            _signDigest(SIGNER_KEY, _digest(escrow, 2, ID, alice, false, vm.getBlockTimestamp()));
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), newSignature);
    }

    function test_WrongDomainNameVersionAndPersonalSignAreRejected() public {
        _openJoined(ID, IMD, 1e18);
        bytes32 resultHash = keccak256(abi.encode(escrow.RESULT_TYPEHASH(), ID, alice, false, vm.getBlockTimestamp()));
        for (uint256 i; i < 2; ++i) {
            bytes32 badDomain = keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    i == 0 ? keccak256("WrongName") : keccak256("SpacePinball"),
                    i == 1 ? keccak256("2") : keccak256("1"),
                    block.chainid,
                    address(escrow)
                )
            );
            bytes memory wrongDomain =
                _signDigest(SIGNER_KEY, keccak256(abi.encodePacked(hex"1901", badDomain, resultHash)));
            vm.expectRevert(PinballEscrow.InvalidSignature.selector);
            escrow.settle(ID, alice, false, vm.getBlockTimestamp(), wrongDomain);
        }
        bytes memory personalSign = _signDigest(
            SIGNER_KEY,
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32", _digest(escrow, 1, ID, alice, false, vm.getBlockTimestamp())
                )
            )
        );
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, alice, false, vm.getBlockTimestamp(), personalSign);
    }

    function test_MalformedInvalidVAndHighSSignaturesRejected() public {
        _openJoined(ID, IMD, 1e18);
        bytes32 digest = _digest(escrow, 1, ID, alice, false, vm.getBlockTimestamp());
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        bytes[6] memory malformed =
            [bytes(""), hex"010203", new bytes(64), new bytes(65), abi.encodePacked(r, s, uint8(1)), highS];
        for (uint256 i; i < malformed.length; ++i) {
            vm.expectRevert(PinballEscrow.InvalidSignature.selector);
            escrow.settle(ID, alice, false, vm.getBlockTimestamp(), malformed[i]);
        }
        _settle(ID, alice, false);
    }

    function test_SignerRotationInvalidatesOutstandingOldKeyResults() public {
        _openJoined(ID, IMD, 5e18);
        uint256 deadline = vm.getBlockTimestamp() + 500;
        bytes memory oldSignature = _signature(ID, bob, false, deadline);
        vm.prank(OWNER);
        escrow.setSigner(vm.addr(OTHER_KEY));
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, oldSignature);
        bytes memory newSignature = _signDigest(OTHER_KEY, _digest(escrow, 1, ID, bob, false, deadline));
        vm.prank(charlie);
        escrow.settle(ID, bob, false, deadline, newSignature);
    }

    function test_ECDSASignerWithCodeCanStillSignDirectly() public {
        vm.etch(resultSigner, hex"60006000fd");
        _openJoined(ID, SHIFT, 100_000e18);
        _settle(ID, alice, false);
        _assertState(ID, PinballEscrow.State.Settled);
    }

    function test_ERC1271SignerAcceptsValidSignatureAndRejectsRevocationAndReverts() public {
        SignerMock contractSigner = new SignerMock(resultSigner);
        vm.prank(OWNER);
        escrow.setSigner(address(contractSigner));
        _openJoined(ID, IMD, 1e18);
        uint256 deadline = vm.getBlockTimestamp() + 500;
        bytes memory signature = _signature(ID, bob, false, deadline);
        bytes memory wrong = _signDigest(OTHER_KEY, _digest(escrow, 1, ID, bob, false, deadline));
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, wrong);
        contractSigner.configure(false, false);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        contractSigner.configure(true, true);
        vm.expectRevert(PinballEscrow.InvalidSignature.selector);
        escrow.settle(ID, bob, false, deadline, signature);
        contractSigner.configure(true, false);
        escrow.settle(ID, bob, false, deadline, signature);
    }

    function test_UnavailableSignerCannotPreventTimedRefund() public {
        SignerMock contractSigner = new SignerMock(resultSigner);
        contractSigner.configure(true, true);
        vm.prank(OWNER);
        escrow.setSigner(address(contractSigner));
        _openJoined(ID, SHIFT, 1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        escrow.refund(ID);
        assertEq(MockToken(SHIFT).balanceOf(alice), START_BALANCE);
        assertEq(MockToken(SHIFT).balanceOf(bob), START_BALANCE);
    }
}
