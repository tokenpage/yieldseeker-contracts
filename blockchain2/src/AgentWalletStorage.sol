// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AgentWalletStorageV1
 * @notice Storage layout for AgentWallet V1 using ERC-7201 namespaced storage pattern
 * @dev Uses deterministic storage slot to avoid collisions with proxy storage and future versions
 */
library AgentWalletStorageV1 {
    /// @custom:storage-location erc7201:agentwallet.storage.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("agentwallet.storage.v1");

    struct Layout {
        address owner;
        uint256 ownerAgentIndex;
        IERC20 baseAsset;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}
