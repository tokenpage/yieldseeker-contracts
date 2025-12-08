// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title AgentWalletStorageV1
 * @notice Storage layout for AgentWallet V1 using ERC-7201 namespaced storage pattern
 * @dev Uses deterministic storage slot to avoid collisions with proxy storage and inherited contracts.
 *      To add fields in V2, either:
 *      1. Append to this struct (safe, fields stay in same namespace)
 *      2. Create AgentWalletStorageV2 with a new namespace for V2-only fields
 */
library AgentWalletStorageV1 {
    /// @custom:storage-location erc7201:yieldseeker.agentwallet.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.v1");

    struct Layout {
        uint256 userAgentIndex;
        address baseAsset;
        address executorModule;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}
