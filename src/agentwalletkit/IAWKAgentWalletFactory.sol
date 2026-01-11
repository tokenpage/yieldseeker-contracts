// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
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
