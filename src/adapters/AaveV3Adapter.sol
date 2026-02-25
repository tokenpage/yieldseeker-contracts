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

import {AWKAaveV3Adapter, IAaveAToken} from "../agentwalletkit/adapters/AWKAaveV3Adapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerAaveV3Adapter
 * @notice YieldSeeker-specific Aave V3 adapter with fee tracking
 * @dev Extends the generic AWKAaveV3Adapter with base asset validation and fee tracking.
 *      Aave uses rebasing tokens (aToken balance grows over time).
 *      Fee computation uses actual vault balance proportion for cost basis.
 */
contract YieldSeekerAaveV3Adapter is AWKAaveV3Adapter, YieldSeekerAdapter {
    /**
     * @notice Internal deposit implementation with validation and fee tracking
     */
    function _depositInternal(address vault, uint256 amount) internal override returns (uint256 shares) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        shares = super._depositInternal(vault, amount);
        _feeTracker().recordAgentVaultShareDeposit({vault: vault, assetsDeposited: amount, sharesReceived: shares});
    }

    /**
     * @notice Internal withdraw implementation with fee tracking
     */
    function _withdrawInternal(address vault, uint256 shares) internal override returns (uint256 assets) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        uint256 totalVaultBalanceBefore = IAaveAToken(vault).balanceOf(address(this));
        assets = super._withdrawInternal(vault, shares);
        _feeTracker().recordAgentVaultAssetWithdraw({vault: vault, assetsReceived: assets, totalVaultBalanceBefore: totalVaultBalanceBefore, vaultTokenToBaseAssetRate: _feeTracker().EXCHANGE_RATE_PRECISION()});
    }
}
