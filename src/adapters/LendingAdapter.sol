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
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../fees/BorrowFeeModule.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldSeekerLendingAdapter
 * @notice YieldSeeker rules and the borrow fee on top of an AWK lending adapter
 * @dev Collateral must be the wallet's base asset and the debt asset must differ from it; which markets can be
 *      used at all is decided by the registry. Every borrow, repay and collateral withdrawal reports the market's
 *      real debt to the borrow fee module. Fees owed are paid from the collateral when it is withdrawn, at the oracle
 *      price; collateral can only leave the protocol that way, so fees cannot be left behind. A missing or stale price
 *      skips that payment so the owner can always exit.
 */
abstract contract YieldSeekerLendingAdapter is AWKLendingAdapter, YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    IYieldSeekerPriceOracle public immutable PRICE_ORACLE;

    constructor(IYieldSeekerPriceOracle priceOracle) {
        if (address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        PRICE_ORACLE = priceOracle;
    }

    /// @dev The borrow fee module of the wallet's tracker; only V3 wallets use lending adapters
    function _feeModule() internal view returns (YieldSeekerBorrowFeeModule module) {
        module = YieldSeekerBorrowFeeModule(address(_feeTracker().feeModules(BORROW_FEE)));
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
        _payFeesFromCollateral(feeModule, debtAsset, collateralAsset);
    }

    /// @dev Pays fees owed in `debtAsset` with the collateral in the wallet, valued at the oracle price
    function _payFeesFromCollateral(YieldSeekerBorrowFeeModule feeModule, address debtAsset, address collateralAsset) internal {
        uint256 owed = feeModule.feesOwed(address(this), debtAsset);
        if (owed == 0) return;
        uint256 owedInCollateral;
        try PRICE_ORACLE.quote(debtAsset, collateralAsset, owed) returns (uint256 quoted) {
            owedInCollateral = quoted;
        } catch {
            return;
        }
        uint256 balance = IERC20(collateralAsset).balanceOf(address(this));
        uint256 payment = owedInCollateral > balance ? balance : owedInCollateral;
        if (payment == 0) return;
        uint256 owedCovered = payment == owedInCollateral ? owed : (owed * payment) / owedInCollateral;
        IERC20(collateralAsset).safeTransfer(_feeTracker().feeCollector(), payment);
        feeModule.recordFeePaid(debtAsset, owedCovered, collateralAsset, payment);
    }
}
