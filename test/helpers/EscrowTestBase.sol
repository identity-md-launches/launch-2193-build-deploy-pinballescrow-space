// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PinballEscrow} from "../../src/PinballEscrow.sol";
import {MockToken} from "./MockToken.sol";

abstract contract EscrowTestBase is Test {
    address internal constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address internal constant SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    bytes32 internal constant ID = keccak256("nightshift-match-1");
    uint256 internal constant START_BALANCE = 100_000_000e18;
    // Local testing keys are never constructor parameters or launch configuration.
    uint256 internal constant SIGNER_KEY = 0xa11ce;
    uint256 internal constant OTHER_KEY = 0xb0b;
    PinballEscrow internal escrow;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal relayer;
    address internal resultSigner;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1_000_000);
        alice = makeAddr("player A");
        bob = makeAddr("player B");
        charlie = makeAddr("third player");
        relayer = makeAddr("permissionless relayer");
        resultSigner = vm.addr(SIGNER_KEY);
        escrow = new PinballEscrow(OWNER);
        vm.prank(OWNER);
        escrow.setSigner(resultSigner);

        MockToken implementation = new MockToken();
        vm.etch(IMD, address(implementation).code);
        vm.etch(SHIFT, address(implementation).code);
        _fundAndApprove(IMD, alice);
        _fundAndApprove(IMD, bob);
        _fundAndApprove(IMD, charlie);
        _fundAndApprove(SHIFT, alice);
        _fundAndApprove(SHIFT, bob);
        _fundAndApprove(SHIFT, charlie);
    }

    function _fundAndApprove(address token, address player) internal {
        MockToken(token).mint(player, START_BALANCE);
        vm.prank(player);
        MockToken(token).approve(address(escrow), START_BALANCE);
    }

    function _open(bytes32 id, address token, uint256 stake) internal {
        vm.prank(alice);
        escrow.open(id, token, stake);
    }

    function _join(bytes32 id) internal {
        vm.prank(bob);
        escrow.join(id);
    }

    function _openJoined(bytes32 id, address token, uint256 stake) internal {
        _open(id, token, stake);
        _join(id);
    }

    // The signing oracle deliberately builds the typed data independently of escrow.hashResult.
    function _digest(PinballEscrow target, uint256 chainId, bytes32 id, address winner, bool draw, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpacePinball"),
                keccak256("1"),
                chainId,
                address(target)
            )
        );
        bytes32 result = keccak256(
            abi.encode(
                keccak256("Result(bytes32 matchId,address winner,bool draw,uint256 deadline)"),
                id,
                winner,
                draw,
                deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, result));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signature(bytes32 id, address winner, bool draw, uint256 deadline) internal view returns (bytes memory) {
        return _signDigest(SIGNER_KEY, _digest(escrow, block.chainid, id, winner, draw, deadline));
    }

    function _settle(bytes32 id, address winner, bool draw) internal {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _signature(id, winner, draw, deadline);
        vm.prank(relayer);
        escrow.settle(id, winner, draw, deadline, signature);
    }

    function _stake(bool shift, uint256 tier) internal pure returns (uint256) {
        uint256[4] memory imdStakes = [uint256(1e18), 5e18, 10e18, 25e18];
        uint256[4] memory shiftStakes = [uint256(100_000e18), 500_000e18, 1_000_000e18, 5_000_000e18];
        return shift ? shiftStakes[tier % 4] : imdStakes[tier % 4];
    }

    function _assertState(bytes32 id, PinballEscrow.State expected) internal view {
        assertEq(uint256(escrow.matches(id).state), uint256(expected));
    }
}
