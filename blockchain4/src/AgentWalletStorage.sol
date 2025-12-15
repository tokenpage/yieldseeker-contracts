// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ActionRegistry} from "./ActionRegistry.sol";

/**
 * @title AgentWalletStorageV1
 * @notice Storage layout for AgentWallet V1 using ERC-7201 namespaced storage pattern
 * @dev Uses deterministic storage slot to avoid collisions with proxy storage and future versions
 */
library AgentWalletStorageV1 {
    /// @custom:storage-location erc7201:yieldseeker.agentwallet.storage.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.storage.v1");

    struct Layout {
        address owner;
        ActionRegistry actionRegistry;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}
