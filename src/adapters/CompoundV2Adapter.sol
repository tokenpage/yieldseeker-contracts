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

import {AWKCompoundV2Adapter, ICToken} from "../agentwalletkit/adapters/AWKCompoundV2Adapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title YieldSeekerCompoundV2Adapter
 * @notice YieldSeeker-specific Compound V2 adapter with fee tracking
 * @dev Extends the generic AWKCompoundV2Adapter with base asset validation and fee tracking.
 *      Compound V2 uses exchange rate model (cToken * exchangeRate = underlying).
 *      Fee computation uses actual underlying balance proportion for cost basis.
 */
contract YieldSeekerCompoundV2Adapter is AWKCompoundV2Adapter, YieldSeekerAdapter {
    /**
     * @notice Internal deposit implementation with validation and fee tracking
     */
    function _depositInternal(address vault, uint256 amount) internal override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        (shares, assetsDeposited) = super._depositInternal(vault, amount);
        _feeTracker().recordAgentVaultShareDeposit({vault: vault, assetsDeposited: assetsDeposited, sharesReceived: shares});
    }

    /**
     * @notice Internal withdraw implementation with fee tracking
     */
    function _withdrawInternal(address vault, uint256 shares) internal override returns (uint256 assets) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        uint256 cTokenBalance = ICToken(vault).balanceOf(address(this));
        uint256 exchangeRate = ICToken(vault).exchangeRateCurrent();
        uint256 compoundExchangeRateScale = 10 ** (18 + uint256(IERC20Metadata(asset).decimals()) - uint256(ICToken(vault).decimals()));
        uint256 totalVaultBalanceBefore = (cTokenBalance * exchangeRate) / compoundExchangeRateScale;
        uint256 normalizedRate = (_feeTracker().ASSET_EXCHANGE_RATE_PRECISION() * exchangeRate) / compoundExchangeRateScale;
        assets = super._withdrawInternal(vault, shares);
        _feeTracker().recordAgentVaultAssetWithdraw({vault: vault, assetsReceived: assets, totalVaultBalanceBefore: totalVaultBalanceBefore, vaultTokenToBaseAssetRate: normalizedRate});
    }
}
