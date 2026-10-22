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

import {IYieldSeekerPriceOracle} from "../PriceOracle.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {YieldSeekerBorrowFeeModule} from "../fees/BorrowFeeModule.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldSeekerLendingAdapter
 * @notice YieldSeeker rules and the borrow fee on top of an AWK lending adapter
 * @dev Collateral must be the wallet's base asset and the debt asset must differ from it; which markets can be
 *      used at all is decided by the registry. Every borrow, repay and collateral withdrawal reports the market's
 *      real debt to the borrow fee module. Fees owed are paid in the borrowed token before each repay. Withdrawing
 *      collateral pays fees owed from the borrowed token and then from the withdrawn collateral at the oracle price,
 *      so fees cannot be left behind. A missing or stale price skips that payment so the owner can always exit.
 */
abstract contract YieldSeekerLendingAdapter is AWKLendingAdapter, YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    IYieldSeekerPriceOracle public immutable PRICE_ORACLE;

    constructor(IYieldSeekerPriceOracle priceOracle) {
        if (address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        PRICE_ORACLE = priceOracle;
    }

    function _feeModule() internal view returns (YieldSeekerBorrowFeeModule module) {
        module = _borrowFeeModule();
        if (address(module) == address(0)) revert AssetNotAllowed();
    }

    function _checkedMarketAssets(bytes memory market) internal view returns (address collateralAsset, address debtAsset) {
        (collateralAsset, debtAsset) = _marketAssets(market);
        _requireBaseAsset(collateralAsset);
        if (debtAsset == collateralAsset) revert AssetNotAllowed();
    }

    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        _checkedMarketAssets(market);
        return super._supplyCollateralOperation(market, amount);
    }

    function _borrowOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 borrowed) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debtBefore = _debtOf(market);
        borrowed = super._borrowOperation(market, amount);
        _feeModule().recordBorrow(keccak256(market), debtAsset, borrowed, debtBefore);
    }

    function _repayOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (, address debtAsset) = _checkedMarketAssets(market);
        YieldSeekerBorrowFeeModule feeModule = _feeModule();
        uint256 debtBefore = _debtOf(market);
        feeModule.checkpoint(keccak256(market), debtAsset, debtBefore);
        _payFees(feeModule, debtAsset, debtAsset);
        uint256 balance = IERC20(debtAsset).balanceOf(address(this));
        uint256 repayAmount = amount == type(uint256).max ? (debtBefore < balance ? debtBefore : balance) : amount;
        if (repayAmount == 0) revert AWKErrors.InsufficientBalance();
        repaid = super._repayOperation(market, repayAmount);
        feeModule.recordRepay(keccak256(market), debtAsset, repaid, debtBefore);
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (address collateralAsset, address debtAsset) = _checkedMarketAssets(market);
        YieldSeekerBorrowFeeModule feeModule = _feeModule();
        feeModule.checkpoint(keccak256(market), debtAsset, _debtOf(market));
        withdrawn = super._withdrawCollateralOperation(market, amount);
        _payFees(feeModule, debtAsset, debtAsset);
        _payFees(feeModule, debtAsset, collateralAsset);
    }

    /// @dev Pays fees owed in `debtAsset` with `paymentAsset`, valued at the oracle price when they differ
    function _payFees(YieldSeekerBorrowFeeModule feeModule, address debtAsset, address paymentAsset) internal {
        uint256 owed = feeModule.feesOwed(address(this), debtAsset);
        if (owed == 0) return;
        uint256 owedInPaymentAsset = owed;
        if (paymentAsset != debtAsset) {
            try PRICE_ORACLE.quote(debtAsset, paymentAsset, owed) returns (uint256 quoted) {
                owedInPaymentAsset = quoted;
            } catch {
                return;
            }
        }
        uint256 balance = IERC20(paymentAsset).balanceOf(address(this));
        uint256 payment = owedInPaymentAsset > balance ? balance : owedInPaymentAsset;
        if (payment == 0) return;
        uint256 owedCovered = payment == owedInPaymentAsset ? owed : (owed * payment) / owedInPaymentAsset;
        IERC20(paymentAsset).safeTransfer(_feeTracker().feeCollector(), payment);
        feeModule.recordFeePaid(debtAsset, owedCovered, paymentAsset, payment);
    }
}
