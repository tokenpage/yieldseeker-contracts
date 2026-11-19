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
import {IAToken as IAaveAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPool as IAaveV3Pool} from "aave-v3/interfaces/IPool.sol";
import {IncentivizedERC20} from "aave-v3/protocol/tokenization/base/IncentivizedERC20.sol";

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
        return IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
    }

    /// @dev The amount is the underlying asset amount; shares are the aToken balance received (1:1 rebasing)
    function _deposit(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = address(IncentivizedERC20(vault).POOL());
        uint256 baseAssetBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 balanceBefore = IAaveAToken(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(pool, amount);
        IAaveV3Pool(pool).supply({asset: asset, amount: amount, onBehalfOf: address(this), referralCode: 0});
        uint256 balanceAfter = IAaveAToken(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        assetsDeposited = baseAssetBalanceBefore - IERC20(asset).balanceOf(address(this));
    }

    /// @dev The shares parameter is the underlying asset amount, since aTokens rebase 1:1; the result is measured as the
    ///      change in the wallet's asset balance
    function _withdraw(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        address asset = IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = address(IncentivizedERC20(vault).POOL());
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        IAaveV3Pool(pool).withdraw({asset: asset, amount: shares, to: address(this)});
        assets = IERC20(asset).balanceOf(address(this)) - balanceBefore;
    }
}
