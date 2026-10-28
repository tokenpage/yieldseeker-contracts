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
 *      used at all is decided by the registry. Every borrow, repay and collateral withdrawal reports the market's
 *      real debt to the fee modules (FeeActions.DEBT_CHANGE), and fees due are paid from the base asset, including
 *      collateral just withdrawn.
 */
abstract contract YieldSeekerLendingAdapter is AWKLendingAdapter, YieldSeekerAdapter {
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
        _reportAction(FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: keccak256(market), debtToken: debtAsset, debtBefore: debtBefore, borrowed: borrowed, repaid: 0})));
    }

    function _repayOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debtBefore = _debtOf(market);
        uint256 balance = IERC20(debtAsset).balanceOf(address(this));
        uint256 repayAmount = amount == type(uint256).max ? (debtBefore < balance ? debtBefore : balance) : amount;
        if (repayAmount == 0) revert AWKErrors.InsufficientBalance();
        repaid = super._repayOperation(market, repayAmount);
        _reportAction(FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: keccak256(market), debtToken: debtAsset, debtBefore: debtBefore, borrowed: 0, repaid: repaid})));
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (, address debtAsset) = _checkedMarketAssets(market);
        uint256 debt = _debtOf(market);
        withdrawn = super._withdrawCollateralOperation(market, amount);
        _reportAction(FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: keccak256(market), debtToken: debtAsset, debtBefore: debt, borrowed: 0, repaid: 0})));
    }
}
