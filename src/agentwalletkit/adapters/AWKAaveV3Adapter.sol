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
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKErrors} from "../AWKErrors.sol";
import {AWKBaseVaultAdapter} from "./AWKBaseVaultAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IAaveV3Pool
 * @notice Minimal Aave V3 Pool interface
 */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title IAaveAToken
 * @notice Minimal Aave aToken interface
 */
interface IAaveAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
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
        return IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
    }

    /**
     * @notice Internal deposit implementation for Aave V3
     * @dev Runs in wallet context via delegatecall. The amount parameter is the underlying asset amount.
     *      For Aave, shares received equals amount deposited (1:1 rebasing).
     */
    function _depositInternal(address vault, uint256 amount) internal virtual override returns (uint256 shares) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        address asset = IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = IAaveAToken(vault).POOL();
        uint256 balanceBefore = IAaveAToken(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(pool, amount);
        IAaveV3Pool(pool).supply({asset: asset, amount: amount, onBehalfOf: address(this), referralCode: 0});
        uint256 balanceAfter = IAaveAToken(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Internal withdraw implementation for Aave V3
     * @dev Runs in wallet context via delegatecall. The shares parameter is treated as underlying asset amount
     *      since Aave uses 1:1 rebasing tokens.
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        if (shares == 0) revert AWKErrors.ZeroAmount();
        address asset = IAaveAToken(vault).UNDERLYING_ASSET_ADDRESS();
        address pool = IAaveAToken(vault).POOL();
        assets = IAaveV3Pool(pool).withdraw({asset: asset, amount: shares, to: address(this)});
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
