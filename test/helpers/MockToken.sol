// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PinballEscrow} from "../../src/PinballEscrow.sol";

/// @dev Test-only adversarial token; its runtime is installed at the two fixed token addresses.
contract MockToken is ERC20 {
    enum DepositMode {
        Exact,
        Short,
        Extra,
        FalseReturn,
        Revert,
        NoReturn
    }

    DepositMode public depositMode;
    address public blockedRecipient;
    bool public noTransferReturn;
    PinballEscrow private callbackTarget;
    bytes private callbackData;
    bytes32 private watchedId;
    bool private onDeposit;
    bool private onTransfer;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackResult;
    PinballEscrow.State public observedState;

    constructor() ERC20("Test token", "TEST") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setDepositMode(DepositMode mode) external {
        depositMode = mode;
    }

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setNoTransferReturn(bool enabled) external {
        noTransferReturn = enabled;
    }

    function configureCallback(PinballEscrow target, bytes memory data, bytes32 id, bool deposit, bool transfer_)
        external
    {
        callbackTarget = target;
        callbackData = data;
        watchedId = id;
        onDeposit = deposit;
        onTransfer = transfer_;
        callbackAttempted = false;
        callbackSucceeded = false;
        delete callbackResult;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (depositMode == DepositMode.Revert) revert("mock deposit failed");
        if (depositMode == DepositMode.FalseReturn) return false;
        super.transferFrom(from, to, amount);
        if (depositMode == DepositMode.Short) _burn(to, 1);
        if (depositMode == DepositMode.Extra) _mint(to, 1);
        if (onDeposit) _callback();
        if (depositMode == DepositMode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) return false;
        super.transfer(to, amount);
        if (onTransfer) _callback();
        if (noTransferReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _callback() private {
        onDeposit = false;
        onTransfer = false;
        callbackAttempted = true;
        observedState = callbackTarget.matches(watchedId).state;
        (callbackSucceeded, callbackResult) = address(callbackTarget).call(callbackData);
    }
}
