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
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKAdapter} from "../agentwalletkit/AWKAdapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../fees/FeeTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error AssetNotAllowed();

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 * @dev Extends AWKAdapter with YieldSeeker-specific helpers for baseAsset and fees. Adapters only report what the
 *      wallet did (_reportAction with a FeeActions action) to the fee tracker, whose modules decide what it costs,
 *      and pay the fees straight away.
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

    function _feeTracker() internal view returns (FeeTracker) {
        return _ysAgentWallet().feeTracker();
    }

    /// @dev Reports an action (FeeActions) to the fee tracker and pays the fees its modules settle
    function _reportAction(bytes32 action, bytes memory data) internal {
        (uint256 payment, address feeCollector) = _feeTracker().reportAction(action, data);
        if (payment > 0) _baseAsset().safeTransfer(feeCollector, payment);
    }
}
