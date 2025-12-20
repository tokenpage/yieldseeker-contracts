// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";

interface IAgentWalletFactory {
    function agentWalletImplementation() external view returns (address);
    function adapterRegistry() external view returns (AdapterRegistry);
    function feeTracker() external view returns (FeeTracker);
    function listAgentOperators() external view returns (address[] memory);
}
