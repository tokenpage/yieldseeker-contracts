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
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../fees/BorrowFeeModule.sol";
import {IYieldSeekerFeeModuleHost} from "../fees/IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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

    /// @dev The wallet's borrow fee module, or address(0) (also for wallets pinned to a tracker without fee modules)
    function _borrowFeeModule() internal view returns (YieldSeekerBorrowFeeModule) {
        address tracker = address(_feeTracker());
        if (!IERC165(tracker).supportsInterface(type(IYieldSeekerFeeModuleHost).interfaceId)) return YieldSeekerBorrowFeeModule(address(0));
        return YieldSeekerBorrowFeeModule(address(IYieldSeekerFeeModuleHost(tracker).feeModules(BORROW_FEE)));
    }

    function _isBorrowedToken(address token) internal view returns (bool) {
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        return address(module) != address(0) && module.isBorrowedToken(address(this), token);
    }
}
