// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {SimpleAccount, IEntryPoint} from "account-abstraction/samples/SimpleAccount.sol";
import {ActionRegistry} from "./ActionRegistry.sol";

/**
 * @title AgentWallet
 * @notice ERC-4337 v0.6 smart wallet for yield-seeking agents, extending SimpleAccount
 * @dev Inherits eth-infinitism SimpleAccount functionality:
 *      - Single owner (EOA)
 *      - ERC-4337 v0.6 EntryPoint compatible (works with Coinbase Paymaster)
 *      - ECDSA signature validation
 *      - UUPS upgradeable
 *      - execute/executeBatch for standard calls
 *
 *      Adds adapter-based execution for DeFi operations:
 *      - executeViaAdapter: delegatecall to registered adapters
 *      - All adapter calls validated against ActionRegistry
 */
contract AgentWallet is SimpleAccount {
    ActionRegistry public actionRegistry;

    event ExecutedViaAdapter(address indexed adapter, bytes data, bytes result);

    error AdapterNotRegistered(address adapter);
    error AdapterExecutionFailed(bytes reason);

    constructor(IEntryPoint anEntryPoint) SimpleAccount(anEntryPoint) {}

    function initialize(address anOwner, ActionRegistry actionRegistry_) public virtual initializer {
        super._initialize(anOwner);
        actionRegistry = actionRegistry_;
    }

    /**
     * @notice Execute a call through a registered adapter via delegatecall
     * @dev Can only be called by EntryPoint or owner. The adapter is delegatecalled,
     *      so it executes in the context of this wallet.
     * @param adapter The registered adapter contract to delegatecall
     * @param data The calldata to pass to the adapter
     * @return result The return data from the adapter call
     */
    function executeViaAdapter(
        address adapter,
        bytes calldata data
    ) external payable virtual returns (bytes memory result) {
        _requireFromEntryPointOrOwner();
        if (!actionRegistry.isRegisteredAdapter(adapter)) {
            revert AdapterNotRegistered(adapter);
        }
        bool success;
        (success, result) = adapter.delegatecall(data);
        if (!success) {
            revert AdapterExecutionFailed(result);
        }
        emit ExecutedViaAdapter(adapter, data, result);
    }

    /**
     * @notice Execute multiple adapter calls in a batch
     * @param adapters Array of adapter addresses
     * @param datas Array of calldata for each adapter
     * @return results Array of return data from each adapter call
     */
    function executeViaAdapterBatch(
        address[] calldata adapters,
        bytes[] calldata datas
    ) external payable virtual returns (bytes[] memory results) {
        _requireFromEntryPointOrOwner();
        uint256 length = adapters.length;
        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            if (!actionRegistry.isRegisteredAdapter(adapters[i])) {
                revert AdapterNotRegistered(adapters[i]);
            }
            (bool success, bytes memory result) = adapters[i].delegatecall(datas[i]);
            if (!success) {
                revert AdapterExecutionFailed(result);
            }
            emit ExecutedViaAdapter(adapters[i], datas[i], result);
            results[i] = result;
        }
    }
}
