// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerFeeLedger as FeeLedger} from "./FeeLedger.sol";

interface IAgentWalletFactory {
    function agentWalletImplementation() external view returns (address);
    function adapterRegistry() external view returns (AdapterRegistry);
    function feeLedger() external view returns (FeeLedger);
    function listAgentOperators() external view returns (address[] memory);
}
