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
 * @title ICToken
 * @notice Minimal Compound V2 cToken/mToken interface (used by Moonwell and other Compound V2 forks)
 */
interface ICToken {
    function underlying() external view returns (address);
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

/**
 * @title AWKCompoundV2Adapter
 * @notice Generic adapter for interacting with Compound V2 style lending protocols (Moonwell, etc.)
 * @dev Handles deposits and withdrawals for Compound V2 style protocols using cTokens/mTokens.
 *      The target address is the cToken/mToken address.
 *      These protocols use exchange rate based tokens where cToken balance * exchangeRate = underlying.
 */
abstract contract AWKCompoundV2Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Fetch underlying asset from cToken/mToken
     */
    function _getVaultAsset(address vault) internal view override returns (address) {
        return ICToken(vault).underlying();
    }

    /**
     * @notice Internal deposit implementation for Compound V2
     * @dev Runs in wallet context via delegatecall. The amount parameter is the underlying asset amount.
     *      Returns the cTokens received as shares.
     */
    function _depositInternal(address vault, uint256 amount) internal virtual override returns (uint256 shares) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        address asset = ICToken(vault).underlying();
        uint256 balanceBefore = ICToken(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(vault, amount);
        uint256 mintResult = ICToken(vault).mint(amount);
        require(mintResult == 0, "AWKCompoundV2Adapter: mint failed");
        uint256 balanceAfter = ICToken(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Internal withdraw implementation for Compound V2
     * @dev Runs in wallet context via delegatecall. The shares parameter represents the underlying amount to withdraw
     *      (redeemUnderlying takes the underlying amount, not cToken amount).
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        if (shares == 0) revert AWKErrors.ZeroAmount();
        uint256 redeemResult = ICToken(vault).redeemUnderlying(shares);
        require(redeemResult == 0, "AWKCompoundV2Adapter: redeem failed");
        assets = shares;
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
