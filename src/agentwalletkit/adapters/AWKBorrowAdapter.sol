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
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKAdapter} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";

error MarketTargetMismatch(address target, address expected);

/**
 * @title AWKBorrowAdapter
 * @notice Base class for borrow adapters: supply and withdraw collateral, borrow and repay, and checkpoint a market
 * @dev Every market is its own registry target: target = marketTarget(market), where `market` is the
 *      protocol-specific encoding of the market (it includes the protocol contract). A market can only be
 *      used once the registry admin has mapped its target to this adapter.
 *      Pass type(uint256).max to withdraw all collateral or repay all debt. checkpoint moves no funds: it reads the
 *      market's current debt so the rules layer can record it (e.g. after a liquidation outside the adapter).
 */
abstract contract AWKBorrowAdapter is AWKAdapter {
    event CollateralSupplied(address indexed wallet, address indexed market, uint256 amount);
    event CollateralWithdrawn(address indexed wallet, address indexed market, uint256 amount);
    event Borrowed(address indexed wallet, address indexed market, uint256 amount);
    event Repaid(address indexed wallet, address indexed market, uint256 amount);
    event Checkpointed(address indexed wallet, address indexed market, uint256 debt);

    /// @dev Only through execute, and only for the market that is the call's target
    modifier onlyMarket(bytes calldata market) {
        address target = _target();
        if (target == address(0)) revert AWKErrors.DirectCallForbidden();
        if (marketTarget(market) != target) revert MarketTargetMismatch(target, marketTarget(market));
        _;
    }

    function supplyCollateral(bytes calldata market, uint256 amount) external onlyMarket(market) returns (uint256 supplied) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        supplied = _supplyCollateralOperation(market, amount);
        emit CollateralSupplied(address(this), _target(), supplied);
    }

    function withdrawCollateral(bytes calldata market, uint256 amount) external onlyMarket(market) returns (uint256 withdrawn) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        withdrawn = _withdrawCollateralOperation(market, amount);
        emit CollateralWithdrawn(address(this), _target(), withdrawn);
    }

    function borrow(bytes calldata market, uint256 amount) external onlyMarket(market) returns (uint256 borrowed) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        borrowed = _borrowOperation(market, amount);
        emit Borrowed(address(this), _target(), borrowed);
    }

    function repay(bytes calldata market, uint256 amount) external onlyMarket(market) returns (uint256 repaid) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        repaid = _repayOperation(market, amount);
        emit Repaid(address(this), _target(), repaid);
    }

    function checkpoint(bytes calldata market) external onlyMarket(market) returns (uint256 debt) {
        debt = _checkpointOperation(market);
        emit Checkpointed(address(this), _target(), debt);
    }

    /// @notice The registry target that identifies a market
    function marketTarget(bytes memory market) public pure returns (address) {
        return address(uint160(uint256(keccak256(market))));
    }

    /// @notice An id for the wallet's collateral position behind a market. Markets that share one collateral balance
    ///         (e.g. two Aave V3 markets with the same pool and collateral) share it
    function collateralPosition(bytes memory market) public view virtual returns (address);

    /// @notice An id for the wallet's debt position behind a market. Markets that share one debt balance (e.g. two Aave V4
    ///         markets with the same spoke and debt reserve) share it
    function debtPosition(bytes memory market) public view virtual returns (address);

    /// @notice The token the wallet holds for its collateral in a market (an Aave V3 aToken), or address(0) when the
    ///         protocol keeps the collateral itself
    /// @dev Register it in the registry as a target of this adapter, next to the market: swap policies never sell a
    ///      registry target, and execute rejects it because it is not a market target
    function collateralReceiptToken(bytes memory market) public view virtual returns (address);

    // ============ Operations (implemented by an operations layer: AWKBorrowOperations or a wallet's rules) ============

    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal virtual returns (uint256);

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal virtual returns (uint256);

    function _borrowOperation(bytes memory market, uint256 amount) internal virtual returns (uint256);

    function _repayOperation(bytes memory market, uint256 amount) internal virtual returns (uint256);

    function _checkpointOperation(bytes memory market) internal virtual returns (uint256 debt);

    // ============ Protocol Implementation ============

    /// @dev The market's collateral and debt assets
    function _marketAssets(bytes memory market) internal view virtual returns (address collateralAsset, address debtAsset);

    /// @dev The wallet's current debt in the market, including accrued interest
    function _debtOf(bytes memory market) internal virtual returns (uint256);

    /// @dev The wallet's current collateral in the market, including any interest it earned
    function _collateralOf(bytes memory market) internal view virtual returns (uint256);

    /// @dev Collateral units worth one debt unit (raw token units, scaled by 1e36), from the market's own oracle: the
    ///      price the protocol itself uses to value this position
    function _debtPriceInCollateral(bytes memory market) internal view virtual returns (uint256);

    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual returns (uint256 supplied);

    /// @dev The withdrawn collateral stays in the wallet
    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual returns (uint256 withdrawn);

    /// @dev The borrowed asset stays in the wallet
    function _borrow(bytes memory market, uint256 amount) internal virtual returns (uint256 borrowed);

    /// @dev Any amount at or above the debt repays all of it
    function _repay(bytes memory market, uint256 amount) internal virtual returns (uint256 repaid);
}

/// @notice The kit's default operations: the protocol calls with no further rules
abstract contract AWKBorrowOperations is AWKBorrowAdapter {
    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal override returns (uint256) {
        return _supplyCollateral(market, amount);
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal override returns (uint256) {
        return _withdrawCollateral(market, amount);
    }

    function _borrowOperation(bytes memory market, uint256 amount) internal override returns (uint256) {
        return _borrow(market, amount);
    }

    function _repayOperation(bytes memory market, uint256 amount) internal override returns (uint256) {
        return _repay(market, amount);
    }

    function _checkpointOperation(bytes memory market) internal override returns (uint256) {
        return _debtOf(market);
    }
}
