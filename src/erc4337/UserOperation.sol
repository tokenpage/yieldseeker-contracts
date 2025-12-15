// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

/**
 * @title UserOperation
 * @notice ERC-4337 v0.6 UserOperation struct
 */
struct UserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    uint256 callGasLimit;
    uint256 verificationGasLimit;
    uint256 preVerificationGas;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    bytes paymasterAndData;
    bytes signature;
}
