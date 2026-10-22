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

import {AWKLendingAdapter} from "./AWKLendingAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAaveV4Spoke {
    struct Reserve {
        address underlying;
        address hub;
        uint16 assetId;
        uint8 decimals;
        uint24 collateralRisk;
        uint8 flags;
        uint32 dynamicConfigKey;
    }

    function getReserve(uint256 reserveId) external view returns (Reserve memory);
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);
    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external returns (uint256, uint256);
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;
}

/**
 * @title AWKAaveV4LendingAdapter
 * @notice Borrow against collateral on an Aave V4 spoke
 * @dev market = abi.encode(address spoke, uint256 collateralReserveId, uint256 debtReserveId).
 */
contract AWKAaveV4LendingAdapter is AWKLendingAdapter {
    using SafeERC20 for IERC20;

    function _decodeMarket(bytes memory market) internal pure returns (IAaveV4Spoke spoke, uint256 collateralReserveId, uint256 debtReserveId) {
        (spoke, collateralReserveId, debtReserveId) = abi.decode(market, (IAaveV4Spoke, uint256, uint256));
    }

    function _marketAssets(bytes memory market) internal view virtual override returns (address collateralAsset, address debtAsset) {
        (IAaveV4Spoke spoke, uint256 collateralReserveId, uint256 debtReserveId) = _decodeMarket(market);
        return (spoke.getReserve(collateralReserveId).underlying, spoke.getReserve(debtReserveId).underlying);
    }

    function _debtOf(bytes memory market) internal view virtual override returns (uint256) {
        (IAaveV4Spoke spoke,, uint256 debtReserveId) = _decodeMarket(market);
        return spoke.getUserTotalDebt(debtReserveId, address(this));
    }

    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IAaveV4Spoke spoke, uint256 collateralReserveId,) = _decodeMarket(market);
        (address collateralAsset,) = _marketAssets(market);
        IERC20(collateralAsset).forceApprove(address(spoke), amount);
        spoke.supply(collateralReserveId, amount, address(this));
        spoke.setUsingAsCollateral(collateralReserveId, true, address(this));
        IERC20(collateralAsset).forceApprove(address(spoke), 0);
        return amount;
    }

    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (IAaveV4Spoke spoke, uint256 collateralReserveId,) = _decodeMarket(market);
        uint256 collateral = spoke.getUserSuppliedAssets(collateralReserveId, address(this));
        withdrawn = amount > collateral ? collateral : amount;
        spoke.withdraw(collateralReserveId, withdrawn, address(this));
    }

    function _borrow(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IAaveV4Spoke spoke,, uint256 debtReserveId) = _decodeMarket(market);
        spoke.borrow(debtReserveId, amount, address(this));
        return amount;
    }

    function _repay(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (IAaveV4Spoke spoke,, uint256 debtReserveId) = _decodeMarket(market);
        (, address debtAsset) = _marketAssets(market);
        uint256 debt = _debtOf(market);
        repaid = amount > debt ? debt : amount;
        IERC20(debtAsset).forceApprove(address(spoke), repaid);
        spoke.repay(debtReserveId, repaid, address(this));
        IERC20(debtAsset).forceApprove(address(spoke), 0);
    }
}
