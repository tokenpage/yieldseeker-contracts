// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockEntryPoint
/// @notice Mock ERC-4337 EntryPoint for integration testing
contract MockEntryPoint {
    mapping(address => uint256) public nonces;

    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );

    function getNonce(address sender, uint192 key) external view returns (uint256) {
        return nonces[sender];
    }

    function incrementNonce(address sender) external {
        nonces[sender]++;
    }

    // Simplified EntryPoint interface for testing
    function validateUserOp(address wallet, uint256 nonce) external view returns (uint256) {
        // Mock validation - in real implementation this would be much more complex
        if (nonces[wallet] != nonce) {
            return 1; // SIG_VALIDATION_FAILED
        }
        return 0; // Successful validation
    }
}
