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
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

interface IWETH {
    function deposit() external payable;
}

/**
 * @title YieldSeekerCompoundV2Adapter
 * @notice YieldSeeker-specific Compound V2 adapter with fee tracking
 * @dev Extends the generic AWKCompoundV2Adapter with base asset validation and fee tracking.
 *      Withdrawals redeem cTokens (shares), so fees use the share-based cost basis, as for ERC4626 vaults.
 *      Underlying paid out as native ETH is wrapped back into the base asset.
 */
contract YieldSeekerCompoundV2Adapter is AWKCompoundV2Adapter, YieldSeekerAdapter {
    /**
     * @notice Internal deposit implementation with validation and fee tracking
     */
    function _depositInternal(address vault, uint256 amount) internal override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        (shares, assetsDeposited) = super._depositInternal(vault, amount);
        _reportAction(FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vault, assetsIn: assetsDeposited})));
    }

    /**
     * @notice Internal withdraw implementation with fee tracking
     */
    function _withdrawInternal(address vault, uint256 shares) internal override returns (uint256 assets) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        uint256 heldBefore = ICToken(vault).balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;
        assets = super._withdrawInternal(vault, shares);
        uint256 nativeAssetsReceived = address(this).balance - nativeBalanceBefore;
        if (nativeAssetsReceived > 0) {
            IWETH(asset).deposit{value: nativeAssetsReceived}();
        }
        _reportAction(FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vault, spent: shares, heldBefore: heldBefore, assetsOut: assets})));
    }
}
