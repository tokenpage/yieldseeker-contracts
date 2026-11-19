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
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKBaseVaultAdapter} from "./AWKBaseVaultAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAToken} from "aave-v3-origin/interfaces/IAToken.sol";
import {IPool} from "aave-v3-origin/interfaces/IPool.sol";

/// @notice The aToken's pool, which Aave's IAToken doesn't expose
interface IAaveAToken {
    function POOL() external view returns (address);
}

/**
 * @title AWKAaveV3Adapter
 * @notice Generic adapter for interacting with Aave V3 lending pools
 * @dev Handles deposits and withdrawals for Aave V3 pools via aTokens.
 *      The target address is the aToken address, and we derive the pool from it.
 *      Aave uses rebasing tokens where balance increases over time.
 */
abstract contract AWKAaveV3Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Fetch underlying asset from aToken
     */
    function _getVaultAsset(address vault) internal view override returns (address) {
        return IAToken(vault).UNDERLYING_ASSET_ADDRESS();
    }

    /// @dev The amount is the underlying asset amount; shares are the aToken balance received (1:1 rebasing)
    function _deposit(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = IAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = IAaveAToken(vault).POOL();
        uint256 baseAssetBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 balanceBefore = IAToken(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(pool, amount);
        IPool(pool).supply({asset: asset, amount: amount, onBehalfOf: address(this), referralCode: 0});
        uint256 balanceAfter = IAToken(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        assetsDeposited = baseAssetBalanceBefore - IERC20(asset).balanceOf(address(this));
    }

    /// @dev The shares parameter is the underlying asset amount, since aTokens rebase 1:1; the result is measured as the
    ///      change in the wallet's asset balance
    function _withdraw(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        address asset = IAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = IAaveAToken(vault).POOL();
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IPool(pool).withdraw({asset: asset, amount: shares, to: address(this)});
        assets = IERC20(asset).balanceOf(address(this)) - balanceBefore;
    }
}
