// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IAWKAdapter
 * @notice Standard interface for all AWK adapters.
 */
interface IAWKAdapter {
    /**
     * @notice Standard entry point for all adapter logic
     * @param target The contract the adapter will interact with (e.g., a vault or swap router)
     * @param data The specific operation data (encoded function call for the adapter)
     * @return result The return data from the operation
     */
    function execute(address target, bytes calldata data) external payable returns (bytes memory);
}
