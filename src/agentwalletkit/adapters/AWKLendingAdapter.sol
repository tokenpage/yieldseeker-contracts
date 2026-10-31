// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";

error MarketTargetMismatch(address target, address expected);

/**
 * @title AWKLendingAdapter
 * @notice Base class for lending adapters: supply and withdraw collateral, borrow and repay
 * @dev Every market is its own registry target: target = marketTarget(market), where `market` is the
 *      protocol-specific encoding of the market (it includes the protocol contract). A market can only be
 *      used once the registry admin has mapped its target to this adapter.
 *      Pass type(uint256).max to withdraw all collateral or repay all debt.
 */
abstract contract AWKLendingAdapter is AWKAdapter {
    event CollateralSupplied(address indexed wallet, address indexed market, uint256 amount);
    event CollateralWithdrawn(address indexed wallet, address indexed market, uint256 amount);
    event Borrowed(address indexed wallet, address indexed market, uint256 amount);
    event Repaid(address indexed wallet, address indexed market, uint256 amount);

    function supplyCollateral(bytes calldata market, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function withdrawCollateral(bytes calldata market, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function borrow(bytes calldata market, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function repay(bytes calldata market, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    /// @notice The registry target that identifies a market
    function marketTarget(bytes memory market) public pure returns (address) {
        return address(uint160(uint256(keccak256(market))));
    }

    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector != this.supplyCollateral.selector && selector != this.withdrawCollateral.selector && selector != this.borrow.selector && selector != this.repay.selector) revert UnknownOperation();
        (bytes memory market, uint256 amount) = abi.decode(data[4:], (bytes, uint256));
        if (marketTarget(market) != target) revert MarketTargetMismatch(target, marketTarget(market));
        if (amount == 0) revert AWKErrors.ZeroAmount();
        uint256 result;
        if (selector == this.supplyCollateral.selector) {
            result = _supplyCollateralOperation(market, amount);
            emit CollateralSupplied(address(this), target, result);
        } else if (selector == this.withdrawCollateral.selector) {
            result = _withdrawCollateralOperation(market, amount);
            emit CollateralWithdrawn(address(this), target, result);
        } else if (selector == this.borrow.selector) {
            result = _borrowOperation(market, amount);
            emit Borrowed(address(this), target, result);
        } else {
            result = _repayOperation(market, amount);
            emit Repaid(address(this), target, result);
        }
        return abi.encode(result);
    }

    // ============ Operations (override to add rules) ============

    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal virtual returns (uint256) {
        return _supplyCollateral(market, amount);
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal virtual returns (uint256) {
        return _withdrawCollateral(market, amount);
    }

    function _borrowOperation(bytes memory market, uint256 amount) internal virtual returns (uint256) {
        return _borrow(market, amount);
    }

    function _repayOperation(bytes memory market, uint256 amount) internal virtual returns (uint256) {
        return _repay(market, amount);
    }

    // ============ Protocol Implementation ============

    /// @dev The market's collateral and debt assets
    function _marketAssets(bytes memory market) internal view virtual returns (address collateralAsset, address debtAsset);

    /// @dev The wallet's current debt in the market, including accrued interest
    function _debtOf(bytes memory market) internal virtual returns (uint256);

    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual returns (uint256 supplied);

    /// @dev The withdrawn collateral stays in the wallet
    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual returns (uint256 withdrawn);

    /// @dev The borrowed asset stays in the wallet
    function _borrow(bytes memory market, uint256 amount) internal virtual returns (uint256 borrowed);

    /// @dev Any amount at or above the debt repays all of it
    function _repay(bytes memory market, uint256 amount) internal virtual returns (uint256 repaid);
}
