// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PinballEscrow} from "../../src/PinballEscrow.sol";
import {MockToken} from "./MockToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Six live slots, unlimited fresh IDs: successful lifecycles remain reachable late in a run.
/// The ledger changes only after successful escrow calls, never by reading escrow balances.
contract ContinuousEscrowHandler is Test {
    uint256 private constant KEY_A = 0xa11ce;
    uint256 private constant KEY_B = 0xb0b;
    uint256 private constant SLOT_COUNT = 6;
    address private constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address private constant SPLITTER = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    address private constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address private constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;

    struct Game {
        bytes32 id;
        address token;
        uint256 stake;
        address a;
        address b;
        uint256 openedAt;
        uint256 joinedAt;
        PinballEscrow.State state;
    }

    struct Ledger {
        uint256 deposits;
        uint256 playerPayments;
        uint256 fees;
        uint256 donations;
    }

    PinballEscrow private immutable escrow;
    uint256 private immutable initialBalance;
    address[3] private actors;
    Game[6] private games;
    Game[] private finished;
    mapping(address => Ledger) private ledger;
    mapping(address => mapping(address => uint256)) private playerBalances;
    uint256 private nextId;
    uint256 private signingKey = KEY_A;
    bool private opensPaused;

    uint256 public opens;
    uint256 public joins;
    uint256 public wins;
    uint256 public draws;
    uint256 public refunds;
    uint256 public failedDeposits;
    uint256 public failedPayments;
    uint256 public rejectedReplays;

    constructor(PinballEscrow target, address[3] memory players, uint256 startingBalance) {
        escrow = target;
        actors = players;
        initialBalance = startingBalance;
        for (uint256 i; i < 3; ++i) {
            playerBalances[IMD][players[i]] = startingBalance;
            playerBalances[SHIFT][players[i]] = startingBalance;
        }
    }

    /// @dev Each selection advances one real lifecycle, replacing finished games with fresh IDs.
    function progress(uint8 slotSeed, bool shift, uint8 tier, uint8 actorSeed, uint8 outcomeSeed) public {
        uint256 slot = slotSeed % SLOT_COUNT;
        Game storage game = games[slot];
        if (game.state == PinballEscrow.State.None || _terminal(game.state)) {
            bytes32 id = _newId();
            address token = shift ? SHIFT : IMD;
            uint256 stake = _stake(shift, tier);
            address a = actors[actorSeed % 3];
            if (opensPaused) {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(a);
                escrow.open(id, token, stake);
                assertEq(uint256(escrow.matches(id).state), uint256(PinballEscrow.State.None));
                return;
            }
            vm.prank(a);
            escrow.open(id, token, stake);
            games[slot] = Game(id, token, stake, a, address(0), vm.getBlockTimestamp(), 0, PinballEscrow.State.Open);
            ledger[token].deposits += stake;
            playerBalances[token][a] -= stake;
            ++opens;
        } else if (game.state == PinballEscrow.State.Open && vm.getBlockTimestamp() < game.openedAt + 1 hours) {
            address b = _otherActor(game.a, actorSeed);
            vm.prank(b);
            escrow.join(game.id);
            game.b = b;
            game.joinedAt = vm.getBlockTimestamp();
            game.state = PinballEscrow.State.Joined;
            ledger[game.token].deposits += game.stake;
            playerBalances[game.token][b] -= game.stake;
            ++joins;
        } else {
            _exit(game, outcomeSeed % 3, false, false);
        }
    }

    /// @dev Force a failure at the token boundary, including after a token has moved funds.
    function rejectDeposit(uint8 slotSeed, bool shift, uint8 tier, uint8 faultSeed, uint8 actorSeed) public {
        Game storage game = games[slotSeed % SLOT_COUNT];
        bool joining = game.state == PinballEscrow.State.Open && vm.getBlockTimestamp() < game.openedAt + 1 hours;
        bytes32 id = joining ? game.id : _newId();
        address token = joining ? game.token : shift ? SHIFT : IMD;
        uint256 stake = joining ? game.stake : _stake(shift, tier);
        address player = joining ? _otherActor(game.a, actorSeed) : actors[actorSeed % 3];
        MockToken coin = MockToken(token);
        uint256 fault = faultSeed % 5;
        bytes memory reason;
        if (!joining && opensPaused) {
            reason = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        } else if (fault == 4) {
            vm.prank(player);
            coin.approve(address(escrow), stake - 1);
            reason = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), stake - 1, stake
            );
        } else {
            coin.setDepositMode(MockToken.DepositMode(fault + 1));
            if (fault < 2) reason = abi.encodeWithSelector(PinballEscrow.IncorrectDeposit.selector);
            else if (fault == 2) reason = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, token);
            else reason = abi.encodeWithSignature("Error(string)", "mock deposit failed");
        }
        bytes32 beforeMatch = keccak256(abi.encode(escrow.matches(id)));
        vm.expectRevert(reason);
        vm.prank(player);
        if (joining) escrow.join(id);
        else escrow.open(id, token, stake);
        assertEq(keccak256(abi.encode(escrow.matches(id))), beforeMatch, "failed deposit changed match");
        // The mock's short/extra transfers must also have rolled back mint/burn and allowances.
        assertEq(
            coin.allowance(player, address(escrow)),
            fault == 4 && (joining || !opensPaused) ? stake - 1 : type(uint256).max
        );
        coin.setDepositMode(MockToken.DepositMode.Exact);
        vm.prank(player);
        coin.approve(address(escrow), type(uint256).max);
        ++failedDeposits;
        checkAccounting();
    }

    /// @dev A blocked first or second recipient must leave the entire exit retryable.
    function failPaymentThenRetry(uint8 slotSeed, uint8 outcomeSeed, bool secondRecipient) public {
        Game storage game = games[slotSeed % SLOT_COUNT];
        if (game.state == PinballEscrow.State.None || _terminal(game.state)) {
            progress(slotSeed, slotSeed % 2 == 1, outcomeSeed, outcomeSeed, outcomeSeed);
            return;
        }
        if (game.state == PinballEscrow.State.Open && vm.getBlockTimestamp() < game.openedAt + 1 hours) {
            vm.warp(game.openedAt + 1 hours);
        }
        _exit(game, outcomeSeed % 3, true, secondRecipient);
    }

    function _exit(Game storage game, uint256 outcome, bool failFirst, bool secondRecipient) private {
        bool joined = game.state == PinballEscrow.State.Joined;
        bool refunding = !joined || vm.getBlockTimestamp() >= game.joinedAt + 24 hours;
        bool draw = outcome == 2;
        address winner = draw ? address(0) : outcome == 0 ? game.a : game.b;
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory signature = _signature(game.id, winner, draw, deadline);
        MockToken coin = MockToken(game.token);
        if (failFirst) {
            address recipient;
            if (refunding || draw) recipient = joined && secondRecipient ? game.b : game.a;
            else recipient = secondRecipient ? SPLITTER : winner;
            coin.setBlockedRecipient(recipient);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, game.token));
            if (refunding) escrow.refund(game.id);
            else escrow.settle(game.id, winner, draw, deadline, signature);
            checkAccounting();
            coin.setBlockedRecipient(address(0));
            ++failedPayments;
        }

        // The handler is neither player nor owner: both exit functions must be permissionless.
        if (refunding) escrow.refund(game.id);
        else escrow.settle(game.id, winner, draw, deadline, signature);
        if (refunding || draw) {
            _credit(game.token, game.a, game.stake);
            if (joined) _credit(game.token, game.b, game.stake);
            if (refunding) ++refunds;
            else ++draws;
        } else {
            uint256 fee = game.stake / 10; // Five percent of a two-stake pot.
            ledger[game.token].fees += fee;
            _credit(game.token, winner, game.stake * 2 - fee);
            ++wins;
        }
        game.state = refunding ? PinballEscrow.State.Refunded : PinballEscrow.State.Settled;
        finished.push(game);
    }

    function advanceTime(uint8 intervalSeed) public {
        uint256[7] memory intervals = [uint256(0), 1, 17, 3599, 3600, 86_399, 86_400];
        vm.warp(vm.getBlockTimestamp() + intervals[intervalSeed % 7]);
    }

    function administer(bool pause_, bool otherKey) public {
        if (pause_ != opensPaused) {
            vm.prank(OWNER);
            if (pause_) escrow.pause();
            else escrow.unpause();
            opensPaused = pause_;
        }
        signingKey = otherKey ? KEY_B : KEY_A;
        address signer = vm.addr(signingKey);
        vm.prank(OWNER);
        escrow.setSigner(signer);
    }

    function donate(bool shift, uint8 actorSeed, uint96 amountSeed) public {
        address token = shift ? SHIFT : IMD;
        address player = actors[actorSeed % 3];
        uint256 amount = bound(uint256(amountSeed), 0, 1e18);
        vm.prank(player);
        assertTrue(MockToken(token).transfer(address(escrow), amount));
        ledger[token].donations += amount;
        playerBalances[token][player] -= amount;
    }

    /// @dev Previously retired IDs are challenged after later opens, pauses and signer rotations.
    function replayFinished(uint256 indexSeed) public {
        if (finished.length == 0) return;
        Game memory game = finished[indexSeed % finished.length];
        bytes32 beforeMatch = keccak256(abi.encode(escrow.matches(game.id)));
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        vm.prank(_otherActor(game.a, 0));
        escrow.join(game.id);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.refund(game.id);
        uint256 deadline = vm.getBlockTimestamp() + 1 days;
        // Even a fresh signature from the current signer cannot revive a finished match.
        bytes memory signature = _signature(game.id, game.a, false, deadline);
        vm.expectRevert(PinballEscrow.InvalidState.selector);
        escrow.settle(game.id, game.a, false, deadline, signature);
        vm.expectRevert(opensPaused ? Pausable.EnforcedPause.selector : PinballEscrow.MatchAlreadyExists.selector);
        vm.prank(game.a);
        escrow.open(game.id, game.token, game.stake);
        assertEq(keccak256(abi.encode(escrow.matches(game.id))), beforeMatch, "terminal match was modified");
        assertEq(uint256(escrow.matches(game.id).state), uint256(game.state));
        ++rejectedReplays;
    }

    function checkAccounting() public view {
        uint256[2] memory obligations;
        for (uint256 i; i < SLOT_COUNT; ++i) {
            Game memory game = games[i];
            if (game.state == PinballEscrow.State.None) continue;
            PinballEscrow.Match memory actual = escrow.matches(game.id);
            assertEq(actual.token, game.token, "recorded token");
            assertEq(actual.stake, game.stake, "recorded stake");
            assertEq(actual.playerA, game.a, "recorded A");
            assertEq(actual.playerB, game.b, "recorded B");
            assertEq(actual.openedAt, game.openedAt, "open time");
            assertEq(actual.joinedAt, game.joinedAt, "join time");
            assertEq(uint256(actual.state), uint256(game.state), "match phase");
            if (game.state == PinballEscrow.State.Open) obligations[game.token == IMD ? 0 : 1] += game.stake;
            if (game.state == PinballEscrow.State.Joined) obligations[game.token == IMD ? 0 : 1] += 2 * game.stake;
        }
        for (uint256 t; t < 2; ++t) {
            address token = t == 0 ? IMD : SHIFT;
            MockToken coin = MockToken(token);
            Ledger memory book = ledger[token];
            assertEq(book.deposits, obligations[t] + book.playerPayments + book.fees, "deposits accounted for");
            assertEq(
                coin.balanceOf(address(escrow)),
                obligations[t] + book.donations,
                "custody equals liabilities plus donations"
            );
            assertEq(coin.balanceOf(SPLITTER), book.fees, "exact fee recipient and amount");
            assertEq(coin.balanceOf(OWNER), 0, "owner cannot take stakes");
            assertEq(coin.balanceOf(address(this)), 0, "relayer cannot take stakes");
            uint256 total = coin.balanceOf(address(escrow)) + coin.balanceOf(SPLITTER);
            for (uint256 a; a < 3; ++a) {
                assertEq(coin.balanceOf(actors[a]), playerBalances[token][actors[a]], "player's independent ledger");
                total += coin.balanceOf(actors[a]);
            }
            assertEq(coin.totalSupply(), initialBalance * 3, "fixed test supply");
            assertEq(total, coin.totalSupply(), "global token conservation");
        }
        assertEq(escrow.owner(), OWNER);
        assertEq(escrow.FEE_RECIPIENT(), SPLITTER);
        assertEq(escrow.FEE_BPS(), 500);
        assertEq(escrow.signer(), vm.addr(signingKey));
        assertEq(escrow.paused(), opensPaused);
    }

    /// @dev Called only by afterInvariant, not among the fuzz targets.
    function drain() external {
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        for (uint256 i; i < SLOT_COUNT; ++i) {
            if (games[i].state == PinballEscrow.State.Open || games[i].state == PinballEscrow.State.Joined) {
                _exit(games[i], 0, false, false);
            }
        }
        checkAccounting();
        assertEq(MockToken(IMD).balanceOf(address(escrow)), ledger[IMD].donations);
        assertEq(MockToken(SHIFT).balanceOf(address(escrow)), ledger[SHIFT].donations);
    }

    function _credit(address token, address player, uint256 amount) private {
        ledger[token].playerPayments += amount;
        playerBalances[token][player] += amount;
    }

    function _newId() private returns (bytes32) {
        return keccak256(abi.encode("continuous matches", nextId++));
    }

    function _otherActor(address a, uint8 seed) private view returns (address) {
        uint256 index = seed % 3;
        return actors[index] == a ? actors[(index + 1) % 3] : actors[index];
    }

    function _terminal(PinballEscrow.State state) private pure returns (bool) {
        return state == PinballEscrow.State.Settled || state == PinballEscrow.State.Refunded;
    }

    function _stake(bool shift, uint8 tier) private pure returns (uint256) {
        uint256[4] memory imd = [uint256(1e18), 5e18, 10e18, 25e18];
        uint256[4] memory shifted = [uint256(100_000e18), 500_000e18, 1_000_000e18, 5_000_000e18];
        return shift ? shifted[tier % 4] : imd[tier % 4];
    }

    function _signature(bytes32 id, address winner, bool draw, uint256 deadline) private view returns (bytes memory) {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, keccak256(abi.encodePacked(hex"1901", domain, result)));
        return abi.encodePacked(r, s, v);
    }
}
