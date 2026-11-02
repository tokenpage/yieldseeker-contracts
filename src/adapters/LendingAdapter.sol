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

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerLendingAdapter
 * @notice YieldSeeker rules on top of an AWK lending adapter
 * @dev Collateral must be the wallet's base asset and the debt asset must differ from it; which markets can be
 *      used at all is decided by the registry. Collateral is a yield fee position like a vault: supplying it reports a
 *      deposit and withdrawing it a withdrawal (target = marketTarget(market)), so interest it earned is charged when
 *      it comes back. Every borrow, repay, collateral withdrawal and checkpoint reports the market's real debt and the
 *      market's own price for it (FeeActions.DEBT_CHANGE), so the borrow fee is valued in the base asset with the
 *      price the protocol itself uses, and fees due are paid from the base asset, including collateral just
 *      withdrawn. The operator checkpoints a market after its debt changed outside the adapter (e.g. a liquidation),
 *      so the borrow fee stops accruing on the old debt.
 */
abstract contract YieldSeekerLendingAdapter is AWKLendingAdapter, YieldSeekerAdapter {
    function _checkedMarketAssets(bytes memory market) internal view returns (address collateralAsset, address debtAsset) {
        (collateralAsset, debtAsset) = _marketAssets(market);
        _requireBaseAsset(collateralAsset);
        if (debtAsset == collateralAsset) revert AssetNotAllowed();
    }

    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 supplied) {
        _checkedMarketAssets(market);
        supplied = super._supplyCollateralOperation(market, amount);
        _reportAction(FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: marketTarget(market), assetsIn: supplied})));
    }

    function _borrowOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 borrowed) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debtBefore = _debtOf(market);
        borrowed = super._borrowOperation(market, amount);
        _reportDebtChange(market, debtAsset, debtBefore, borrowed, 0);
    }

    function _repayOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debtBefore = _debtOf(market);
        uint256 repayAmount = amount;
        if (amount == type(uint256).max) {
            uint256 balance = IERC20(debtAsset).balanceOf(address(this));
            repayAmount = debtBefore < balance ? debtBefore : balance;
        }
        if (repayAmount == 0) revert AWKErrors.InsufficientBalance();
        repaid = super._repayOperation(market, repayAmount);
        _reportDebtChange(market, debtAsset, debtBefore, 0, repaid);
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debt = _debtOf(market);
        uint256 collateralBefore = _collateralOf(market);
        withdrawn = super._withdrawCollateralOperation(market, amount);
        _reportAction(FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: marketTarget(market), spent: withdrawn, heldBefore: collateralBefore, assetsOut: withdrawn})));
        _reportDebtChange(market, debtAsset, debt, 0, 0);
    }

    function _checkpointOperation(bytes memory market) internal virtual override returns (uint256 debt) {
        (, address debtAsset) = _checkedMarketAssets(market);
        debt = super._checkpointOperation(market);
        _reportDebtChange(market, debtAsset, debt, 0, 0);
    }

    /// @dev The market's price is only read while it has debt (no debt, no fee to value)
    function _reportDebtChange(bytes memory market, address debtAsset, uint256 debtBefore, uint256 borrowed, uint256 repaid) internal {
        uint256 debtPrice = debtBefore > 0 ? _debtPriceInCollateral(market) : 0;
        _reportAction(FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: keccak256(market), debtToken: debtAsset, debtBefore: debtBefore, borrowed: borrowed, repaid: repaid, debtPriceInBaseAsset: debtPrice})));
    }
}
