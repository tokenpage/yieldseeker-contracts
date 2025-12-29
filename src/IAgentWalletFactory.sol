// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";

/**
 * @title IAgentWalletFactory
 * @notice Interface for the YieldSeeker agent wallet factory
 * @dev Used by wallets to sync configuration from the factory
 */
interface IAgentWalletFactory {
    /// @notice Get the current approved wallet implementation
    function agentWalletImplementation() external view returns (address);

    /// @notice Get the adapter registry contract
    function adapterRegistry() external view returns (AdapterRegistry);

    /// @notice Get the fee tracker contract
    function feeTracker() external view returns (FeeTracker);

    /// @notice Get all registered agent operators
    function listAgentOperators() external view returns (address[] memory);
}
