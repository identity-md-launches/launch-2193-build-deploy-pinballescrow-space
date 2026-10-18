// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EscrowTestBase, PinballEscrow, MockToken} from "./helpers/EscrowTestBase.sol";

/// @dev Independent accounting/state model. Failed calls are checked, not silently discarded.
contract EscrowHandler is Test {
    enum ModelState {
        None,
        Open,
        Joined,
        Settled,
        Refunded
    }

    struct ModelMatch {
        address token;
        uint256 stake;
        address playerA;
        address playerB;
        uint256 openedAt;
        uint256 joinedAt;
        ModelState state;
    }

    uint256 private constant KEY_A = 0xa11ce;
    uint256 private constant KEY_B = 0xb0b;
    uint256 public constant MATCH_COUNT = 12;
    PinballEscrow private immutable escrow;
    address private immutable owner;
    address private immutable splitter;
    address[2] private tokens;
    address[3] private actors;
    ModelMatch[12] private games;
    mapping(address token => mapping(address player => uint256)) private balances;
    mapping(address token => uint256) private fees;
    mapping(address token => uint256) private donations;
    uint256 private signingKey = KEY_A;
    bool private opensPaused;
    uint256 public successfulOpens;
    uint256 public successfulJoins;
    uint256 public successfulSettlements;
    uint256 public successfulRefunds;
    uint256 public rejectedCalls;

    constructor(PinballEscrow target, address[3] memory players, uint256 startingBalance) {
        escrow = target;
        owner = target.owner();
        splitter = target.FEE_RECIPIENT();
        tokens = [target.IMD(), target.SHIFT()];
        actors = players;
        for (uint256 t; t < 2; ++t) {
            for (uint256 p; p < 3; ++p) {
                balances[tokens[t]][actors[p]] = startingBalance;
            }
        }
    }

    function openMatch(uint8 idSeed, uint8 tokenSeed, uint8 tier, uint8 actorSeed, bool validStake) public {
        uint256 index = idSeed % MATCH_COUNT;
        ModelMatch storage model = games[index];
        address token = tokenSeed % 3 == 2 ? address(this) : tokens[tokenSeed % 3];
        uint256[4] memory imd = [uint256(1e18), 5e18, 10e18, 25e18];
        uint256[4] memory shift = [uint256(100_000e18), 500_000e18, 1_000_000e18, 5_000_000e18];
        uint256 stake = validStake ? (token == tokens[0] ? imd[tier % 4] : shift[tier % 4]) : uint256(tier);
        address player = actors[actorSeed % 3];
        bool expected = model.state == ModelState.None && !opensPaused && token != address(this) && validStake;
        vm.prank(player);
        (bool ok,) = address(escrow).call(abi.encodeCall(escrow.open, (_id(index), token, stake)));
        _checkOutcome(ok, expected);
        if (!ok) return;
        games[index] = ModelMatch(token, stake, player, address(0), vm.getBlockTimestamp(), 0, ModelState.Open);
        balances[token][player] -= stake;
        ++successfulOpens;
    }

    function joinMatch(uint8 idSeed, uint8 actorSeed) public {
        uint256 index = idSeed % MATCH_COUNT;
        ModelMatch storage model = games[index];
        address player = actors[actorSeed % 3];
        bool expected =
            model.state == ModelState.Open && player != model.playerA && vm.getBlockTimestamp() < model.openedAt + 3600;
        vm.prank(player);
        (bool ok,) = address(escrow).call(abi.encodeCall(escrow.join, (_id(index))));
        _checkOutcome(ok, expected);
        if (!ok) return;
        model.playerB = player;
        model.joinedAt = vm.getBlockTimestamp();
        model.state = ModelState.Joined;
        balances[model.token][player] -= model.stake;
        ++successfulJoins;
    }

    function settleMatch(uint8 idSeed, uint8 outcomeSeed, bool validSignature, bool expired) public {
        uint256 index = idSeed % MATCH_COUNT;
        ModelMatch storage model = games[index];
        uint256 outcome = outcomeSeed % 4;
        bool draw = outcome == 2;
        address winner = draw ? address(0) : outcome == 0 ? model.playerA : outcome == 1 ? model.playerB : address(this);
        uint256 deadline = expired ? vm.getBlockTimestamp() - 1 : vm.getBlockTimestamp() + 600;
        uint256 key = validSignature ? signingKey : signingKey == KEY_A ? KEY_B : KEY_A;
        bytes memory signature = _signature(_id(index), winner, draw, deadline, key);
        bool expected = model.state == ModelState.Joined && vm.getBlockTimestamp() < model.joinedAt + 86_400
            && outcome != 3 && validSignature && !expired;
        (bool ok,) =
            address(escrow).call(abi.encodeCall(escrow.settle, (_id(index), winner, draw, deadline, signature)));
        _checkOutcome(ok, expected);
        if (!ok) return;
        model.state = ModelState.Settled;
        if (draw) {
            balances[model.token][model.playerA] += model.stake;
            balances[model.token][model.playerB] += model.stake;
        } else {
            uint256 fee = model.stake / 10;
            balances[model.token][winner] += model.stake * 2 - fee;
            fees[model.token] += fee;
        }
        ++successfulSettlements;
    }

    function refundMatch(uint8 idSeed, uint8 actorSeed) public {
        uint256 index = idSeed % MATCH_COUNT;
        ModelMatch storage model = games[index];
        bool joined = model.state == ModelState.Joined;
        bool expected = (model.state == ModelState.Open && vm.getBlockTimestamp() >= model.openedAt + 3600)
            || (joined && vm.getBlockTimestamp() >= model.joinedAt + 86_400);
        vm.prank(actors[actorSeed % 3]);
        (bool ok,) = address(escrow).call(abi.encodeCall(escrow.refund, (_id(index))));
        _checkOutcome(ok, expected);
        if (!ok) return;
        model.state = ModelState.Refunded;
        balances[model.token][model.playerA] += model.stake;
        if (joined) balances[model.token][model.playerB] += model.stake;
        ++successfulRefunds;
    }

    function advanceTime(uint8 jump) public {
        uint256[6] memory intervals = [uint256(0), 1, 60, 3599, 3600, 86_400];
        vm.warp(vm.getBlockTimestamp() + intervals[jump % 6]);
    }

    function togglePause(bool pause_, bool authorized) public {
        bool expected = authorized && pause_ != opensPaused;
        vm.prank(authorized ? owner : actors[0]);
        (bool ok,) =
            address(escrow).call(pause_ ? abi.encodeCall(escrow.pause, ()) : abi.encodeCall(escrow.unpause, ()));
        _checkOutcome(ok, expected);
        if (ok) opensPaused = pause_;
    }

    function rotateSigner(bool useOtherKey, bool authorized) public {
        uint256 key = useOtherKey ? KEY_B : KEY_A;
        address newSigner = vm.addr(key);
        vm.prank(authorized ? owner : actors[1]);
        (bool ok,) = address(escrow).call(abi.encodeCall(escrow.setSigner, (newSigner)));
        _checkOutcome(ok, authorized);
        if (ok) signingKey = key;
    }

    function donate(uint8 tokenSeed, uint8 actorSeed, uint96 amountSeed) public {
        address token = tokens[tokenSeed % 2];
        address player = actors[actorSeed % 3];
        uint256 amount = uint256(amountSeed) % 1e18;
        vm.prank(player);
        assertTrue(MockToken(token).transfer(address(escrow), amount));
        balances[token][player] -= amount;
        donations[token] += amount;
    }

    function checkModelAndConservation() public view {
        uint256[2] memory liabilities;
        for (uint256 i; i < MATCH_COUNT; ++i) {
            ModelMatch memory model = games[i];
            PinballEscrow.Match memory actual = escrow.matches(_id(i));
            assertEq(uint256(actual.state), uint256(model.state), "state model");
            assertEq(actual.token, model.token, "token model");
            assertEq(actual.stake, model.stake, "stake model");
            assertEq(actual.playerA, model.playerA, "A model");
            assertEq(actual.playerB, model.playerB, "B model");
            assertEq(actual.openedAt, model.openedAt, "open time model");
            assertEq(actual.joinedAt, model.joinedAt, "join time model");
            if (model.state == ModelState.Open || model.state == ModelState.Joined) {
                liabilities[model.token == tokens[0] ? 0 : 1] += model.stake * (model.state == ModelState.Open ? 1 : 2);
            }
        }
        for (uint256 t; t < 2; ++t) {
            MockToken token = MockToken(tokens[t]);
            uint256 escrowBalance = token.balanceOf(address(escrow));
            assertEq(escrowBalance, liabilities[t] + donations[tokens[t]], "fully funded liabilities plus donations");
            assertEq(token.balanceOf(splitter), fees[tokens[t]], "exact fee ledger");
            assertEq(token.balanceOf(owner), 0, "owner received no stakes");
            uint256 accounted = escrowBalance + fees[tokens[t]];
            for (uint256 p; p < 3; ++p) {
                assertEq(token.balanceOf(actors[p]), balances[tokens[t]][actors[p]], "player ledger");
                accounted += balances[tokens[t]][actors[p]];
            }
            assertEq(accounted, token.totalSupply(), "global conservation");
        }
        assertEq(escrow.paused(), opensPaused);
        assertEq(escrow.signer(), vm.addr(signingKey));
        assertEq(escrow.owner(), owner);
        assertEq(escrow.FEE_RECIPIENT(), splitter);
        assertEq(escrow.FEE_BPS(), 500);
    }

    function assertNoStakesRemain() external view {
        for (uint256 t; t < 2; ++t) {
            assertEq(
                MockToken(tokens[t]).balanceOf(address(escrow)), donations[tokens[t]], "all remaining stakes refundable"
            );
        }
    }

    function _checkOutcome(bool ok, bool expected) private {
        assertEq(ok, expected, "call success differs from independent model");
        if (!ok) ++rejectedCalls;
    }

    function _id(uint256 index) private pure returns (bytes32) {
        return bytes32(index); // Includes the all-zero match ID.
    }

    function _signature(bytes32 id, address winner, bool draw, uint256 deadline, uint256 key)
        private
        view
        returns (bytes memory)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SpacePinball"),
                keccak256("1"),
                block.chainid,
                address(escrow)
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(hex"1901", domain, result)));
        return abi.encodePacked(r, s, v);
    }
}

contract PinballEscrowInvariantTest is EscrowTestBase {
    EscrowHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new EscrowHandler(escrow, [alice, bob, charlie], START_BALANCE);
        // Seed active matches so every invariant run exercises outstanding liabilities from the start.
        handler.openMatch(0, 0, 0, 0, true);
        handler.joinMatch(0, 1);
        handler.openMatch(1, 1, 3, 2, true);
        handler.joinMatch(1, 0);
        handler.openMatch(2, 0, 3, 1, true);
        handler.openMatch(3, 1, 1, 0, true);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = EscrowHandler.openMatch.selector;
        selectors[1] = EscrowHandler.joinMatch.selector;
        selectors[2] = EscrowHandler.settleMatch.selector;
        selectors[3] = EscrowHandler.refundMatch.selector;
        selectors[4] = EscrowHandler.advanceTime.selector;
        selectors[5] = EscrowHandler.togglePause.selector;
        selectors[6] = EscrowHandler.rotateSigner.selector;
        selectors[7] = EscrowHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_StateAndBalancesAlwaysMatchTheIndependentModel() public view {
        handler.checkModelAndConservation();
    }

    function afterInvariant() public {
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        for (uint8 i; i < 12; ++i) {
            handler.refundMatch(i, i);
        }
        handler.checkModelAndConservation();
        handler.assertNoStakesRemain();
    }
}
