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

import {YieldSeekerFeeTracker as FeeTracker} from "../FeeTracker.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKAdapter} from "../agentwalletkit/AWKAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error AssetNotAllowed();
error BaseAssetNotAllowed();

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 * @dev Extends AWKAdapter with YieldSeeker-specific helpers for baseAsset and feeTracker
 */
abstract contract YieldSeekerAdapter is AWKAdapter {
    // Helper to get the wallet as IAgentWallet instead of IAWKAgentWallet
    function _ysAgentWallet() internal view returns (IAgentWallet) {
        return IAgentWallet(address(this));
    }

    function _baseAsset() internal view returns (IERC20) {
        return _ysAgentWallet().baseAsset();
    }

    function _baseAssetAddress() internal view returns (address) {
        return address(_baseAsset());
    }

    function _requireBaseAsset(address asset) internal view {
        if (asset != _baseAssetAddress()) revert AssetNotAllowed();
    }

    function _requireNotBaseAsset(address asset) internal view {
        if (asset == _baseAssetAddress()) revert BaseAssetNotAllowed();
    }

    function _feeTracker() internal view returns (FeeTracker) {
        return _ysAgentWallet().feeTracker();
    }
}
