// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ActionRegistry} from "../ActionRegistry.sol";

/**
 * @title BatchRouter
 * @notice Enables batching multiple adapter delegatecalls in a single wallet transaction
 * @dev Solves the limitation where you can only do one delegatecall per transaction.
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
     */
    function executeBatch(address[] calldata adapters, bytes[] calldata actionDatas) external {
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
            (bool success,) = adapter.delegatecall(actionDatas[i]);
            if (!success) {
                revert AdapterCallFailed(i, adapter);
            }
        }
        emit BatchExecuted(length);
    }
}
