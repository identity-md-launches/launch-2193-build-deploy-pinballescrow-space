// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PinballEscrow
/// @notice Two-player Space Pinball stakes, settled by NIGHTSHIFT's signed replay result.
/// @dev The owner is fixed and has only signer rotation and open-pause powers. Match IDs are never reused.
contract PinballEscrow is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant owner = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant SHIFT = 0xE5e58E53d0Bb204Aa62c995A6c8CC8a48e60C3AC;
    address public constant FEE_RECIPIENT = 0x1119d5Df2f046bC2d3c0F6279EF2E9cE49422d44;
    uint256 public constant FEE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant JOIN_WINDOW = 1 hours;
    uint256 public constant SETTLEMENT_WINDOW = 24 hours;
    bytes32 public constant RESULT_TYPEHASH =
        keccak256("Result(bytes32 matchId,address winner,bool draw,uint256 deadline)");

    enum State {
        None,
        Open,
        Joined,
        Settled,
        Refunded
    }

    struct Match {
        address token;
        uint256 stake;
        address playerA;
        address playerB;
        uint256 openedAt;
        uint256 joinedAt;
        State state;
    }

    address public signer;
    mapping(bytes32 matchId => Match) private _matches;

    event Opened(bytes32 indexed matchId, address indexed token, uint256 stake, address indexed playerA);
    event Joined(bytes32 indexed matchId, address indexed playerB);
    /// @param payout Total amount paid to players: winner payout, or both refunds combined for a draw.
    event Settled(bytes32 indexed matchId, address indexed winner, bool draw, uint256 payout, uint256 fee);
    event Refunded(bytes32 indexed matchId);
    event SignerUpdated(address indexed previousSigner, address indexed newSigner);

    error Unauthorized();
    error InvalidInitialSigner();
    error InvalidSigner();
    error UnsupportedToken();
    error InvalidStake();
    error MatchAlreadyExists();
    error InvalidState();
    error CannotJoinOwnMatch();
    error JoinWindowClosed();
    error SettlementWindowClosed();
    error RefundNotReady();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidWinner();
    error IncorrectDeposit();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @param initialSigner Must equal the fixed launch owner; the owner may rotate it after launch.
    /// @dev Does not call other contracts, so construction also works on an empty chain.
    constructor(address initialSigner) EIP712("SpacePinball", "1") {
        if (initialSigner != owner) revert InvalidInitialSigner();
        signer = initialSigner;
        emit SignerUpdated(address(0), initialSigner);
    }

    /// @notice Returns the complete match, including its permanent final state.
    function matches(bytes32 matchId) external view returns (Match memory) {
        return _matches[matchId];
    }

    /// @notice Stakes are base units; both allowed tokens have 18 decimals.
    function isAllowedStake(address token, uint256 stake) public pure returns (bool) {
        if (token == IMD) return stake == 1e18 || stake == 5e18 || stake == 10e18 || stake == 25e18;
        if (token == SHIFT) {
            return stake == 100_000e18 || stake == 500_000e18 || stake == 1_000_000e18 || stake == 5_000_000e18;
        }
        return false;
    }

    /// @notice Deposits player A's stake. Any bytes32 ID is valid, but can be opened only once.
    function open(bytes32 matchId, address token, uint256 stake) external nonReentrant whenNotPaused {
        if (_matches[matchId].state != State.None) revert MatchAlreadyExists();
        if (token != IMD && token != SHIFT) revert UnsupportedToken();
        if (!isAllowedStake(token, stake)) revert InvalidStake();

        _matches[matchId] = Match({
            token: token,
            stake: stake,
            playerA: msg.sender,
            playerB: address(0),
            openedAt: block.timestamp,
            joinedAt: 0,
            state: State.Open
        });
        emit Opened(matchId, token, stake, msg.sender);
        _deposit(token, msg.sender, stake);
    }

    /// @notice Deposits player B's matching stake before the one-hour join window closes.
    /// @dev Existing opens can be joined while paused. The first eligible joiner becomes player B.
    function join(bytes32 matchId) external nonReentrant {
        Match storage game = _matches[matchId];
        if (game.state != State.Open) revert InvalidState();
        if (msg.sender == game.playerA) revert CannotJoinOwnMatch();
        if (block.timestamp >= game.openedAt + JOIN_WINDOW) revert JoinWindowClosed();

        game.playerB = msg.sender;
        game.joinedAt = block.timestamp;
        game.state = State.Joined;
        emit Joined(matchId, msg.sender);
        _deposit(game.token, msg.sender, game.stake);
    }

    /// @notice Anyone may relay the current signer's result before the settlement timeout.
    /// @param winner One of the two players for a win; address(0) for a draw.
    /// @param deadline Last timestamp at which the signature is valid (inclusive).
    function settle(bytes32 matchId, address winner, bool draw, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        Match storage game = _matches[matchId];
        if (game.state != State.Joined) revert InvalidState();
        if (block.timestamp >= game.joinedAt + SETTLEMENT_WINDOW) revert SettlementWindowClosed();
        if (block.timestamp > deadline) revert SignatureExpired();
        if (draw ? winner != address(0) : (winner != game.playerA && winner != game.playerB)) revert InvalidWinner();

        bytes32 digest = hashResult(matchId, winner, draw, deadline);
        // ECDSA first also permits EOAs with delegated code to sign directly.
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        if (
            (error != ECDSA.RecoverError.NoError || recovered != signer)
                && !SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature)
        ) revert InvalidSignature();

        game.state = State.Settled;
        uint256 pot = game.stake * 2;
        IERC20 token = IERC20(game.token);
        if (draw) {
            emit Settled(matchId, address(0), true, pot, 0);
            token.safeTransfer(game.playerA, game.stake);
            token.safeTransfer(game.playerB, game.stake);
        } else {
            uint256 fee = (pot * FEE_BPS) / BPS_DENOMINATOR;
            uint256 payout = pot - fee;
            emit Settled(matchId, winner, false, payout, fee);
            token.safeTransfer(winner, payout);
            token.safeTransfer(FEE_RECIPIENT, fee);
        }
    }

    /// @notice Anyone may trigger expired-match refunds, always to the original depositors.
    /// @dev Available at openedAt + 1 hour for Open, or joinedAt + 24 hours for Joined.
    function refund(bytes32 matchId) external nonReentrant {
        Match storage game = _matches[matchId];
        bool joined = game.state == State.Joined;
        if (game.state != State.Open && !joined) revert InvalidState();
        uint256 eligibleAt = joined ? game.joinedAt + SETTLEMENT_WINDOW : game.openedAt + JOIN_WINDOW;
        if (block.timestamp < eligibleAt) revert RefundNotReady();

        game.state = State.Refunded;
        emit Refunded(matchId);
        IERC20(game.token).safeTransfer(game.playerA, game.stake);
        if (joined) IERC20(game.token).safeTransfer(game.playerB, game.stake);
    }

    /// @notice Immediately changes the signer used for all unsettled matches.
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidSigner();
        address previousSigner = signer;
        signer = newSigner;
        emit SignerUpdated(previousSigner, newSigner);
    }

    /// @notice Stops only new opens; joins, settlement and refunds remain available.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice EIP-712 digest that the server signs, including this contract and the current chain ID.
    function hashResult(bytes32 matchId, address winner, bool draw, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(RESULT_TYPEHASH, matchId, winner, draw, deadline)));
    }

    function _deposit(address token, address player, uint256 stake) private {
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(player, address(this), stake);
        if (IERC20(token).balanceOf(address(this)) != beforeBalance + stake) revert IncorrectDeposit();
    }
}
