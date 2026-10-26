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
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKMerklAdapter} from "../agentwalletkit/adapters/AWKMerklAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter with fee tracking
 * @dev Rewards claimed in the base asset are yield and pay the vault fee at once. Other reward tokens pay it when they
 *      are sold (swap adapter) or, for vault shares, when they are withdrawn from the vault.
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal override {
        uint256 baseAssetBefore = _baseAsset().balanceOf(address(this));
        super._claimInternal(distributor, users, tokens, amounts, proofs);
        uint256 claimed = _baseAsset().balanceOf(address(this)) - baseAssetBefore;
        if (claimed > 0) {
            _vaultFeeModule().recordYield(claimed);
            _payVaultFees();
        }
    }
}
