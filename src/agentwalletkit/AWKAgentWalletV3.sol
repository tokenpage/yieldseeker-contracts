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
import {TooManyOperators} from "./AWKAgentWalletFactory.sol";
import {AgentWalletStorageV1, NotAllowed} from "./AWKAgentWalletV1.sol";
import {AWKAgentWalletV2, AgentWalletStorageV2} from "./AWKAgentWalletV2.sol";
import {AWKErrors} from "./AWKErrors.sol";

/**
 * @title AWKAgentWalletV3
 * @notice AWKAgentWalletV2 that can also run without a factory
 * @dev An implementation deployed with factory == address(0) is self-managed: the owner sets the adapter
 *      registry and operators and chooses its own upgrades. With a factory, behaviour is exactly V2.
 *      Deploy self-managed wallets behind an ERC1967Proxy that calls initialize() in its constructor.
 */
abstract contract AWKAgentWalletV3 is AWKAgentWalletV2 {
    uint256 public constant MAX_OPERATORS = 10;

    event AdapterRegistrySet(address indexed adapterRegistry);
    event AgentOperatorsSet(address[] operators);

    modifier onlySelfManaged() {
        if (_hasFactory()) revert NotAllowed();
        _;
    }

    constructor(address factory) AWKAgentWalletV2(factory) {}

    function _hasFactory() internal view returns (bool) {
        return address(FACTORY) != address(0);
    }

    // ============ Factory Configuration ============

    function _syncFromFactory() internal virtual override {
        if (_hasFactory()) super._syncFromFactory();
    }

    function upgradeToLatest() external virtual override onlyOwner {
        if (!_hasFactory()) revert NotAllowed();
        upgradeToAndCall(FACTORY.agentWalletImplementation(), "");
        _syncFromFactory();
    }

    function _authorizeUpgrade(address newImplementation) internal view virtual override onlyOwner {
        if (_hasFactory()) super._authorizeUpgrade(newImplementation);
    }

    // ============ Self-Managed Configuration ============

    function setAdapterRegistry(AdapterRegistry newAdapterRegistry) external virtual onlyOwner onlySelfManaged {
        if (address(newAdapterRegistry).code.length == 0) revert AWKErrors.NotAContract(address(newAdapterRegistry));
        AgentWalletStorageV2.layout().adapterRegistry = newAdapterRegistry;
        emit AdapterRegistrySet(address(newAdapterRegistry));
    }

    function setAgentOperators(address[] calldata operators) external virtual onlyOwner onlySelfManaged {
        if (operators.length > MAX_OPERATORS) revert TooManyOperators();
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV2.layout();
        for (uint256 i = 0; i < $.agentOperators.length; i++) {
            $.isAgentOperator[$.agentOperators[i]] = false;
        }
        for (uint256 i = 0; i < operators.length; i++) {
            if (operators[i] == address(0)) revert AWKErrors.ZeroAddress();
            $.isAgentOperator[operators[i]] = true;
        }
        $.agentOperators = operators;
        emit AgentOperatorsSet(operators);
    }
}
