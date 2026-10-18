// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract SignerMock is IERC1271 {
    address private immutable key;
    bool public enabled = true;
    bool public shouldRevert;

    constructor(address key_) {
        key = key_;
    }

    function configure(bool enabled_, bool revert_) external {
        enabled = enabled_;
        shouldRevert = revert_;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        require(!shouldRevert, "signer unavailable");
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signature);
        if (enabled && error == ECDSA.RecoverError.NoError && recovered == key) {
            return IERC1271.isValidSignature.selector;
        }
        return bytes4(0xffffffff);
    }
}
