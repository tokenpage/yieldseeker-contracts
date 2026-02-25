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
 * @title ICompoundV3Comet
 * @notice Minimal Compound V3 Comet interface
 */
interface ICompoundV3Comet {
    function baseToken() external view returns (address);
    function supply(address asset, uint256 amount) external;
    function supplyTo(address to, address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function withdrawTo(address to, address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title AWKCompoundV3Adapter
 * @notice Generic adapter for interacting with Compound V3 (Comet) lending markets
 * @dev Handles deposits and withdrawals for Compound V3 Comet markets.
 *      The target address is the Comet market itself.
 *      Compound V3 uses rebasing balance where balance increases over time.
 */
abstract contract AWKCompoundV3Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Fetch base token from Comet market
     */
    function _getVaultAsset(address vault) internal view override returns (address) {
        return ICompoundV3Comet(vault).baseToken();
    }

    /**
     * @notice Internal deposit implementation for Compound V3
     * @dev Runs in wallet context via delegatecall. The amount parameter is the base token amount.
     *      Returns the change in balance as shares (though Compound V3 uses rebasing, not actual shares).
     */
    function _depositInternal(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        address asset = ICompoundV3Comet(vault).baseToken();
        uint256 baseAssetBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 balanceBefore = ICompoundV3Comet(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(vault, amount);
        ICompoundV3Comet(vault).supply({asset: asset, amount: amount});
        uint256 balanceAfter = ICompoundV3Comet(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        assetsDeposited = baseAssetBalanceBefore - IERC20(asset).balanceOf(address(this));
        emit Deposited(address(this), vault, assetsDeposited, shares);
    }

    /**
     * @notice Internal withdraw implementation for Compound V3
     * @dev Runs in wallet context via delegatecall. The shares parameter represents the amount to withdraw
     *      (in Compound V3, balance and assets are equivalent due to rebasing).
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        if (shares == 0) revert AWKErrors.ZeroAmount();
        address asset = ICompoundV3Comet(vault).baseToken();
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        ICompoundV3Comet(vault).withdraw({asset: asset, amount: shares});
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        assets = balanceAfter - balanceBefore;
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
