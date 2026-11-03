// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAaveV3Adapter} from "../agentwalletkit/adapters/AWKAaveV3Adapter.sol";
import {AWKBaseVaultAdapter} from "../agentwalletkit/adapters/AWKBaseVaultAdapter.sol";
import {YieldSeekerVaultAdapter} from "./VaultAdapter.sol";

/**
 * @title YieldSeekerAaveV3Adapter
 * @notice YieldSeeker Aave V3 vault adapter: the AWK protocol code plus the shared YieldSeeker vault rules and fee reports
 */
contract YieldSeekerAaveV3Adapter is AWKAaveV3Adapter, YieldSeekerVaultAdapter {
    function _depositOperation(address vault, uint256 amount) internal override(AWKBaseVaultAdapter, YieldSeekerVaultAdapter) returns (uint256, uint256) {
        return super._depositOperation(vault, amount);
    }

    function _withdrawOperation(address vault, uint256 shares) internal override(AWKBaseVaultAdapter, YieldSeekerVaultAdapter) returns (uint256) {
        return super._withdrawOperation(vault, shares);
    }
}
