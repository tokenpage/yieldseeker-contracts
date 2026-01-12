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
import {AWKCompoundV2Adapter} from "../agentwalletkit/adapters/AWKCompoundV2Adapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IYSCToken
 * @notice Extended cToken interface with redeem function
 */
interface IYSCToken {
    function underlying() external view returns (address);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

/**
 * @title YieldSeekerCompoundV2Adapter
 * @notice YieldSeeker-specific Compound V2 adapter with fee tracking via virtual shares
 * @dev Extends the generic AWKCompoundV2Adapter and implements virtual share tracking.
 *      Compound V2 uses exchange rate model (cToken * exchangeRate = underlying).
 *      We use virtual shares like Aave/CompoundV3 for consistency:
 *      - On deposit: virtualShares = assetsDeposited (1:1 at deposit time)
 *      - On withdraw: convert virtualShares to cTokens using tracked ratio
 *      This makes yield appear as share price appreciation to FeeTracker.
 */
contract YieldSeekerCompoundV2Adapter is AWKCompoundV2Adapter, YieldSeekerAdapter {
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
     * @dev Converts virtual shares to cTokens, then redeems for underlying:
     *      1. Get current underlying value of all cTokens
     *      2. Calculate proportion of cTokens to redeem based on virtual shares
     *      3. Redeem cTokens for underlying
     */
    function _withdrawInternal(address vault, uint256 virtualShares) internal override returns (uint256 assets) {
        if (virtualShares == 0) revert AWKErrors.ZeroAmount();
        address asset = _getVaultAsset(vault);
        _requireBaseAsset(asset);
        uint256 cTokenBalance = IYSCToken(vault).balanceOf(address(this));
        (, uint256 totalVirtualShares) = _feeTracker().getAgentVaultPosition(address(this), vault);
        uint256 cTokensToRedeem = cTokenBalance;
        if (totalVirtualShares > 0 && cTokenBalance > 0) {
            cTokensToRedeem = (cTokenBalance * virtualShares) / totalVirtualShares;
        }
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 redeemResult = IYSCToken(vault).redeem(cTokensToRedeem);
        require(redeemResult == 0, "YSCompoundV2Adapter: redeem failed");
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        assets = balanceAfter - balanceBefore;
        emit Withdrawn(address(this), vault, virtualShares, assets);
        _feeTracker().recordAgentVaultShareWithdraw({vault: vault, sharesSpent: virtualShares, assetsReceived: assets});
    }
}
