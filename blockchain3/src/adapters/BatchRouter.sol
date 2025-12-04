// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ActionRegistry} from "../ActionRegistry.sol";

/**
 * @title BatchRouter
 * @notice Enables batching multiple adapter delegatecalls in a single wallet transaction
 * @dev Solves the ERC-7579 limitation where batch mode only supports regular calls, not delegatecalls.
 *
 *      Background:
 *      ERC-7579 defines callType as a mutually exclusive byte:
 *      - 0x00 = single call
 *      - 0x01 = batch call (multiple targets via regular CALL)
 *      - 0xff = delegatecall (single target)
 *
 *      The spec explicitly notes: "you can delegatecall to a multicall contract to batch delegatecalls"
 *      This contract implements that pattern.
 *
 *      How it works:
 *      1. Wallet delegatecalls to BatchRouter.executeBatch(actions)
 *      2. BatchRouter code runs in wallet context (address(this) = wallet)
 *      3. BatchRouter iterates through actions, delegatecalling each adapter
 *      4. Each adapter also runs in wallet context
 *      5. All actions succeed or all revert (atomic execution)
 *
 *      Security:
 *      - BatchRouter itself is registered as an adapter
 *      - Each sub-adapter must also be registered
 *      - Same trust model as calling adapters individually
 *      - Atomic execution is MORE secure (no partial state)
 *
 *      Usage via AgentActionRouter:
 *      ```
 *      bytes memory batchData = abi.encodeCall(
 *          BatchRouter.executeBatch,
 *          (adapters, actionDatas)
 *      );
 *      router.executeAdapterAction(wallet, batchRouter, batchData);
 *      ```
 */
contract BatchRouter {
    address public immutable self;
    ActionRegistry public immutable registry;

    uint256 public constant MAX_BATCH_SIZE = 20;

    error InvalidBatchLength();
    error BatchTooLarge();
    error EmptyBatch();
    error AdapterNotRegistered(address adapter);
    error AdapterCallFailed(uint256 index, address adapter);
    error NotDelegateCall();

    event BatchExecuted(uint256 actionCount);

    constructor(address _registry) {
        self = address(this);
        registry = ActionRegistry(_registry);
    }

    /**
     * @notice Execute multiple adapter actions via delegatecall
     * @param adapters Array of registered adapter addresses
     * @param actionDatas Array of encoded function calls for each adapter
     * @dev Must be called via delegatecall from a wallet. Each adapter is delegatecalled
     *      in sequence, so all adapter code runs in the wallet's context.
     *
     *      Example: Deposit into two vaults in one transaction:
     *      ```
     *      adapters = [erc4626Adapter, erc4626Adapter]
     *      actionDatas = [
     *          abi.encodeCall(ERC4626Adapter.deposit, (vault1, 100e6)),
     *          abi.encodeCall(ERC4626Adapter.deposit, (vault2, 200e6))
     *      ]
     *      ```
     */
    function executeBatch(
        address[] calldata adapters,
        bytes[] calldata actionDatas
    ) external {
        if (address(this) == self) revert NotDelegateCall();
        uint256 length = adapters.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (length != actionDatas.length) revert InvalidBatchLength();
        for (uint256 i = 0; i < length; ++i) {
            address adapter = adapters[i];
            if (!registry.isRegisteredAdapter(adapter)) {
                revert AdapterNotRegistered(adapter);
            }
            (bool success, ) = adapter.delegatecall(actionDatas[i]);
            if (!success) {
                revert AdapterCallFailed(i, adapter);
            }
        }
        emit BatchExecuted(length);
    }
}
