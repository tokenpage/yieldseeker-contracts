// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {UserOperation} from "./UserOperation.sol";

/**
 * @title IEntryPoint
 * @notice ERC-4337 v0.6 EntryPoint interface
 * @dev Canonical v0.6 EntryPoint: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
 */
interface IEntryPoint {
    function handleOps(UserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(UserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;

    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );

    event AccountDeployed(bytes32 indexed userOpHash, address indexed sender, address factory, address paymaster);

    error FailedOp(uint256 opIndex, string reason);
}
