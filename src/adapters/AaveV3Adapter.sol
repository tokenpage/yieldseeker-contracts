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

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKAaveV3Adapter, IAaveAToken, IAaveV3Pool} from "../agentwalletkit/adapters/AWKAaveV3Adapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldSeekerAaveV3Adapter
 * @notice YieldSeeker-specific Aave V3 adapter with fee tracking via virtual shares
 * @dev Extends the generic AWKAaveV3Adapter and implements virtual share tracking.
 *      Aave uses rebasing tokens (aToken balance grows over time). To enable proper
 *      fee tracking, we treat aTokens as a yield-daddy style wrapper:
 *      - On deposit: virtualShares = assetsDeposited (1:1 at deposit time)
 *      - On withdraw: convert virtualShares to actual aTokens using current exchange rate
 *      This makes rebasing yield appear as share price appreciation to FeeTracker.
 */
contract YieldSeekerAaveV3Adapter is AWKAaveV3Adapter, YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Internal deposit implementation with validation and fee tracking
     * @dev Records virtual shares = assets deposited (1:1 at deposit time)
     */
    function _depositInternal(address vault, uint256 amount) internal override returns (uint256 shares) {
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        shares = super._depositInternal(vault, amount);
        _feeTracker().recordAgentVaultShareDeposit({vault: vault, assetsDeposited: amount, sharesReceived: amount});
    }

    /**
     * @notice Internal withdraw implementation with virtual share conversion
     * @dev Converts virtual shares to actual aTokens using exchange rate:
     *      aTokensToWithdraw = (currentBalance * virtualShares) / totalVirtualShares
     */
    function _withdrawInternal(address vault, uint256 virtualShares) internal override returns (uint256 assets) {
        if (virtualShares == 0) revert AWKErrors.ZeroAmount();
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        uint256 currentBalance = IAaveAToken(vault).balanceOf(address(this));
        (, uint256 totalVirtualShares) = _feeTracker().getAgentVaultPosition(address(this), vault);
        uint256 aTokensToWithdraw = virtualShares;
        if (totalVirtualShares > 0 && currentBalance > 0) {
            aTokensToWithdraw = (currentBalance * virtualShares) / totalVirtualShares;
        }
        address pool = IAaveAToken(vault).POOL();
        assets = IAaveV3Pool(pool).withdraw({asset: asset, amount: aTokensToWithdraw, to: address(this)});
        emit Withdrawn(address(this), vault, virtualShares, assets);
        _feeTracker().recordAgentVaultShareWithdraw({vault: vault, sharesSpent: virtualShares, assetsReceived: assets});
    }
}
