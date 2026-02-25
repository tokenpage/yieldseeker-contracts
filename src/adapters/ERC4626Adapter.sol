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

import {AWKERC4626Adapter} from "../agentwalletkit/adapters/AWKERC4626Adapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title YieldSeekerERC4626Adapter
 * @notice YieldSeeker-specific ERC4626 adapter with fee tracking
 * @dev Extends the generic AWKERC4626Adapter and implements post hooks for fee tracking.
 *      Records position changes with FeeTracker for yield fee calculation.
 */
contract YieldSeekerERC4626Adapter is AWKERC4626Adapter, YieldSeekerAdapter {
    /**
     * @notice Internal deposit implementation with validation and fee tracking
     * @dev Overrides AWK logic to add pre-check and post-fee-tracking
     */
    function _depositInternal(address vault, uint256 amount) internal override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        (shares, assetsDeposited) = super._depositInternal(vault, amount);
        _feeTracker().recordAgentVaultShareDeposit({vault: vault, assetsDeposited: assetsDeposited, sharesReceived: shares});
    }

    /**
     * @notice Internal withdraw implementation with validation and fee tracking
     * @dev Overrides AWK logic to add pre-check and post-fee-tracking
     */
    function _withdrawInternal(address vault, uint256 shares) internal override returns (uint256 assets) {
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        assets = super._withdrawInternal(vault, shares);
        _feeTracker().recordAgentVaultShareWithdraw({vault: vault, sharesSpent: shares, assetsReceived: assets});
    }
}
