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
