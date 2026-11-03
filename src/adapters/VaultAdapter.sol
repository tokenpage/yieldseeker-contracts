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

import {AWKBaseVaultAdapter} from "../agentwalletkit/adapters/AWKBaseVaultAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerVaultAdapter
 * @notice Rules and fee reporting shared by every YieldSeeker vault adapter
 * @dev Only vaults of the wallet's base asset. Deposits and withdrawals are reported to the fee modules
 *      (FeeActions.DEPOSIT / WITHDRAW, target = the vault). A withdrawal's share of the position is measured on the
 *      wallet's vault token balance (shares, cTokens, or the rebasing aToken / Comet balance), before and after.
 */
abstract contract YieldSeekerVaultAdapter is AWKBaseVaultAdapter, YieldSeekerAdapter {
    function _depositOperation(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        _requireBaseAsset(_getVaultAsset(vault));
        (shares, assetsDeposited) = super._depositOperation(vault, amount);
        _reportAction(FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vault, assetsIn: assetsDeposited})));
    }

    function _withdrawOperation(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        _requireBaseAsset(_getVaultAsset(vault));
        uint256 heldBefore = IERC20(vault).balanceOf(address(this));
        assets = super._withdrawOperation(vault, shares);
        uint256 spent = heldBefore - IERC20(vault).balanceOf(address(this));
        _reportAction(FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vault, spent: spent, heldBefore: heldBefore, assetsOut: assets})));
    }
}
