// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {IAccount} from "./IAccount.sol";
import {IEntryPoint} from "./IEntryPoint.sol";
import {UserOperation} from "./UserOperation.sol";

/**
 * @title BaseAccount
 * @notice Minimal ERC-4337 v0.6 account base implementation
 * @dev Adapted from eth-infinitism/account-abstraction v0.6.0
 */
abstract contract BaseAccount is IAccount {
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    function entryPoint() public view virtual returns (IEntryPoint);

    function getNonce() public view virtual returns (uint256) {
        return entryPoint().getNonce(address(this), 0);
    }

    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external virtual override returns (uint256 validationData) {
        _requireFromEntryPoint();
        validationData = _validateSignature(userOp, userOpHash);
        _validateNonce(userOp.nonce);
        _payPrefund(missingAccountFunds);
    }

    function _requireFromEntryPoint() internal view virtual {
        require(msg.sender == address(entryPoint()), "account: not from EntryPoint");
    }

    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash) internal virtual returns (uint256 validationData);

    function _validateNonce(uint256 nonce) internal view virtual {}

    function _payPrefund(uint256 missingAccountFunds) internal virtual {
        if (missingAccountFunds != 0) {
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds, gas: type(uint256).max}("");
            (success);
        }
    }
}
