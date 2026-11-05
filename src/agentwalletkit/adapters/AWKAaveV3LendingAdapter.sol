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
pragma solidity 0.8.38;

import {AWKLendingAdapter} from "./AWKLendingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAaveV3LendingPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function setUserEMode(uint8 categoryId) external;
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    function getUserEMode(address user) external view returns (uint256);
    function getReserveAToken(address asset) external view returns (address);
    function getReserveVariableDebtToken(address asset) external view returns (address);
    function ADDRESSES_PROVIDER() external view returns (IAaveV3AddressesProvider);
}

interface IAaveV3AddressesProvider {
    function getPriceOracle() external view returns (IAaveV3Oracle);
}

interface IAaveV3Oracle {
    /// @notice Price of one whole `asset` in the oracle's base currency (the same unit for every asset)
    function getAssetPrice(address asset) external view returns (uint256);
}

/**
 * @title AWKAaveV3LendingAdapter
 * @notice Borrow against collateral on an Aave V3 pool (variable rate)
 * @dev market = abi.encode(address pool, address collateralAsset, address debtAsset, uint8 eModeCategory).
 *      Supplying collateral puts the account in the market's e-mode category (0 = none). Needs an Aave V3.3+ pool
 *      (getReserveAToken / getReserveVariableDebtToken, about 20k gas cheaper than getReserveData).
 */
contract AWKAaveV3LendingAdapter is AWKLendingAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant VARIABLE_RATE_MODE = 2;

    function _decodeMarket(bytes memory market) internal pure returns (IAaveV3LendingPool pool, address collateralAsset, address debtAsset, uint8 eModeCategory) {
        (pool, collateralAsset, debtAsset, eModeCategory) = abi.decode(market, (IAaveV3LendingPool, address, address, uint8));
    }

    function _marketAssets(bytes memory market) internal view virtual override returns (address collateralAsset, address debtAsset) {
        (, collateralAsset, debtAsset,) = _decodeMarket(market);
    }

    function _debtOf(bytes memory market) internal view virtual override returns (uint256) {
        (IAaveV3LendingPool pool,, address debtAsset,) = _decodeMarket(market);
        return IERC20(pool.getReserveVariableDebtToken(debtAsset)).balanceOf(address(this));
    }

    function collateralReceiptToken(bytes memory market) public view virtual override returns (address) {
        (IAaveV3LendingPool pool, address collateralAsset,,) = _decodeMarket(market);
        return pool.getReserveAToken(collateralAsset);
    }

    function _collateralOf(bytes memory market) internal view virtual override returns (uint256) {
        return IERC20(collateralReceiptToken(market)).balanceOf(address(this));
    }

    /// @dev A zero price can't value the debt, so it is reported as 0 (borrows then revert, other actions use the last
    ///      price); the Base AaveOracle itself reverts on a non-positive source answer
    function _debtPriceInCollateral(bytes memory market) internal view virtual override returns (uint256) {
        (IAaveV3LendingPool pool, address collateralAsset, address debtAsset,) = _decodeMarket(market);
        IAaveV3Oracle oracle = pool.ADDRESSES_PROVIDER().getPriceOracle();
        uint256 debtValue = oracle.getAssetPrice(debtAsset) * 10 ** IERC20Metadata(collateralAsset).decimals();
        uint256 collateralValue = oracle.getAssetPrice(collateralAsset) * 10 ** IERC20Metadata(debtAsset).decimals();
        if (collateralValue == 0) return 0;
        return Math.mulDiv(debtValue, 1e36, collateralValue);
    }

    /// @dev Enables the supply as collateral explicitly: Aave only does that on the account's first supply of the asset,
    ///      and never for an isolation-mode asset. The call does nothing when it is already enabled, and reverts for a
    ///      reserve with LTV 0 (it can't back a borrow), so such a supply fails here rather than at borrow time.
    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IAaveV3LendingPool pool, address collateralAsset,, uint8 eModeCategory) = _decodeMarket(market);
        IERC20(collateralAsset).forceApprove(address(pool), amount);
        pool.supply({asset: collateralAsset, amount: amount, onBehalfOf: address(this), referralCode: 0});
        IERC20(collateralAsset).forceApprove(address(pool), 0);
        pool.setUserUseReserveAsCollateral(collateralAsset, true);
        if (pool.getUserEMode(address(this)) != eModeCategory) pool.setUserEMode(eModeCategory);
        return amount;
    }

    /// @dev Capped at the wallet's collateral like the other lending adapters (Aave reverts above the balance unless
    ///      asked for everything)
    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IAaveV3LendingPool pool, address collateralAsset,,) = _decodeMarket(market);
        uint256 requested = amount >= _collateralOf(market) ? type(uint256).max : amount;
        return pool.withdraw({asset: collateralAsset, amount: requested, to: address(this)});
    }

    function _borrow(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IAaveV3LendingPool pool,, address debtAsset,) = _decodeMarket(market);
        pool.borrow({asset: debtAsset, amount: amount, interestRateMode: VARIABLE_RATE_MODE, referralCode: 0, onBehalfOf: address(this)});
        return amount;
    }

    function _repay(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (IAaveV3LendingPool pool,, address debtAsset,) = _decodeMarket(market);
        uint256 debt = _debtOf(market);
        bool isFullRepay = amount >= debt;
        IERC20(debtAsset).forceApprove(address(pool), isFullRepay ? debt : amount);
        repaid = pool.repay({asset: debtAsset, amount: isFullRepay ? type(uint256).max : amount, interestRateMode: VARIABLE_RATE_MODE, onBehalfOf: address(this)});
        IERC20(debtAsset).forceApprove(address(pool), 0);
    }
}
