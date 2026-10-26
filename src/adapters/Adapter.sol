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
 *      wallet did (_report*); every fee module decides what it charges for, and each report pays the fees due.
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

    function _reportDeposit(address target, uint256 assetsIn) internal {
        IYieldSeekerFeeModule[] memory modules = _feeModules();
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i].onDeposit(target, assetsIn);
        }
        _payFees(modules);
    }

    function _reportWithdraw(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) internal {
        IYieldSeekerFeeModule[] memory modules = _feeModules();
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i].onWithdraw(target, spent, heldBefore, assetsOut);
        }
        _payFees(modules);
    }

    function _reportSwap(address sold, uint256 soldAmount, address bought, uint256 boughtAmount) internal {
        IYieldSeekerFeeModule[] memory modules = _feeModules();
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i].onSwap(sold, soldAmount, bought, boughtAmount);
        }
        _payFees(modules);
    }

    function _reportClaim(address token, uint256 amount) internal {
        IYieldSeekerFeeModule[] memory modules = _feeModules();
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i].onClaim(token, amount);
        }
        _payFees(modules);
    }

    function _reportDebtChange(bytes32 market, address debtToken, uint256 debtBefore, uint256 borrowed, uint256 repaid) internal {
        IYieldSeekerFeeModule[] memory modules = _feeModules();
        for (uint256 i = 0; i < modules.length; i++) {
            modules[i].onDebtChange(market, debtToken, debtBefore, borrowed, repaid);
        }
        _payFees(modules);
    }

    function _payFees() internal {
        _payFees(_feeModules());
    }

    /// @dev Pays each module's fees due to the fee collector from the base asset in the wallet
    function _payFees(IYieldSeekerFeeModule[] memory modules) internal {
        IERC20 baseAsset = _baseAsset();
        address feeCollector = _feeTracker().feeCollector();
        for (uint256 i = 0; i < modules.length; i++) {
            uint256 due = modules[i].feesDue(address(this));
            if (due == 0) continue;
            uint256 balance = baseAsset.balanceOf(address(this));
            uint256 payment = due > balance ? balance : due;
            if (payment == 0) return;
            baseAsset.safeTransfer(feeCollector, payment);
            modules[i].recordFeePaid(payment);
        }
    }

    function _feeModules() internal view returns (IYieldSeekerFeeModule[] memory modules) {
        FeeTracker tracker = _feeTracker();
        bytes32[] memory feeTypes = tracker.moduleFeeTypes();
        modules = new IYieldSeekerFeeModule[](feeTypes.length);
        for (uint256 i = 0; i < feeTypes.length; i++) {
            modules[i] = tracker.feeModules(feeTypes[i]);
        }
    }
}
