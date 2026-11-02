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

import {AWKAdapterRegistry as AdapterRegistry} from "./AWKAdapterRegistry.sol";
import {AWKAgentWalletV3, AgentWalletStorageV3, NotAllowed} from "./AWKAgentWalletV3.sol";
import {AWKErrors} from "./AWKErrors.sol";

/**
 * @title AWKSelfManagedAgentWalletV3
 * @notice AWKAgentWalletV3 without a factory: the owner sets the adapter registry and operators and chooses upgrades.
 * @dev Deploy behind an ERC1967Proxy that calls initialize() in its constructor, so nobody else can initialize it.
 *      syncFromFactory() does nothing, upgradeToLatest() reverts and any implementation the owner picks is accepted.
 *      The agent profile is stored but unused.
 *
 *      IMPORTANT: This contract is abstract and must be inherited, like AWKAgentWalletV3.
 */
abstract contract AWKSelfManagedAgentWalletV3 is AWKAgentWalletV3 {
    event AdapterRegistrySet(address indexed adapterRegistry);
    event AgentOperatorsSet(address[] operators);

    constructor() AWKAgentWalletV3(address(0)) {}

    function setAdapterRegistry(AdapterRegistry newAdapterRegistry) external virtual onlyOwner {
        if (address(newAdapterRegistry).code.length == 0) revert AWKErrors.NotAContract(address(newAdapterRegistry));
        AgentWalletStorageV3.layout().adapterRegistry = newAdapterRegistry;
        emit AdapterRegistrySet(address(newAdapterRegistry));
    }

    function setAgentOperators(address[] calldata operators) external virtual onlyOwner {
        _setAgentOperators(operators);
        emit AgentOperatorsSet(operators);
    }

    function _syncFromFactory() internal virtual override {}

    function upgradeToLatest() external virtual override {
        revert NotAllowed();
    }

    function _authorizeUpgrade(address) internal view virtual override onlyOwner {}
}
