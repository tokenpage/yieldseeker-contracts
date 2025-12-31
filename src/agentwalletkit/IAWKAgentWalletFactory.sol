// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAWKAgentWalletFactory
 * @notice Interface for the AWK agent wallet factory
 * @dev Used by wallets to sync configuration from the factory
 */
interface IAWKAgentWalletFactory {
    /// @notice Get the current approved wallet implementation
    function agentWalletImplementation() external view returns (address);

    /// @notice Get the adapter registry contract
    function adapterRegistry() external view returns (address);

    /// @notice Get all registered agent operators
    function listAgentOperators() external view returns (address[] memory);
}
