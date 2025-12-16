// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {UserOperation} from "./UserOperation.sol";

/**
 * @title IAccount
 * @notice ERC-4337 v0.6 Account interface
 */
interface IAccount {
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 validationData);
}
