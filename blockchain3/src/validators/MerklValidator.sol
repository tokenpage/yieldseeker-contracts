// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IPolicyValidator.sol";

/**
 * @title MerklValidator
 * @notice Example validator for Merkl Distributor claims.
 * @dev Enforces that the agent can only claim rewards for itself.
 */
contract MerklValidator is IPolicyValidator {
    // claim(address[],address[],uint256[],bytes32[][])
    bytes4 public constant CLAIM_SELECTOR = 0x3d13f874;

    function validateAction(address wallet, address target, bytes4 selector, bytes calldata data) external pure override returns (bool) {
        // 1. Check Selector (redundant if Policy maps correctly, but good for safety)
        if (selector != CLAIM_SELECTOR) return false;

        // 2. Decode Arguments
        // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
        // We only care about the first argument: address[] users
        (address[] memory users,,,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));

        // 3. Validate Logic
        // Ensure the agent is only claiming for itself
        for (uint256 i = 0; i < users.length; i++) {
            if (users[i] != wallet) {
                return false;
            }
        }

        return true;
    }
}
