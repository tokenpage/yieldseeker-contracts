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

import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKAdapter} from "../agentwalletkit/AWKAdapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../fees/IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error AssetNotAllowed();
error BaseAssetNotAllowed();

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 * @dev Extends AWKAdapter with YieldSeeker-specific helpers for baseAsset and fees. Adapters only report what the
 *      wallet did (_report with a FeeActions action); every fee module decides what it charges for, and each report
 *      pays the fees due.
 */
abstract contract YieldSeekerAdapter is AWKAdapter {
    using SafeERC20 for IERC20;

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

    /// @dev Reports an action (FeeActions) to every fee module and sends the fees they settle to the fee collector
    function _report(bytes32 action, bytes memory data) internal {
        (IYieldSeekerFeeModule[] memory modules, address feeCollector) = _feeTracker().feeModulesAndCollector();
        IERC20 baseAsset = _baseAsset();
        uint256 available = baseAsset.balanceOf(address(this));
        uint256 payment;
        for (uint256 i = 0; i < modules.length; i++) {
            payment += modules[i].onAction(action, data, address(baseAsset), available - payment);
        }
        if (payment > 0) baseAsset.safeTransfer(feeCollector, payment);
    }
}
