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

import {AWKBorrowAdapter, AWKBorrowOperations} from "./AWKBorrowAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorphoStaticTyping as IMorphoBlue, Id, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {IOracle as IMorphoOracle} from "morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

/**
 * @title AWKMorphoBlueBorrowAdapterCore
 * @notice Borrow against collateral on a Morpho Blue market, without an operations layer
 * @dev market = abi.encode(address morpho, MarketParams). Full repays go by shares so no interest dust is left.
 */
abstract contract AWKMorphoBlueBorrowAdapterCore is AWKBorrowAdapter {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    function _decodeMarket(bytes memory market) internal pure returns (IMorphoBlue morpho, MarketParams memory marketParams, Id id) {
        (morpho, marketParams) = abi.decode(market, (IMorphoBlue, MarketParams));
        id = marketParams.id();
    }

    function _marketAssets(bytes memory market) internal view virtual override returns (address collateralAsset, address debtAsset) {
        (, MarketParams memory marketParams,) = _decodeMarket(market);
        return (marketParams.collateralToken, marketParams.loanToken);
    }

    function _debtOf(bytes memory market) internal virtual override returns (uint256) {
        (IMorphoBlue morpho, MarketParams memory marketParams, Id id) = _decodeMarket(market);
        morpho.accrueInterest(marketParams);
        (, uint128 borrowShares,) = morpho.position(id, address(this));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(id);
        return uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function collateralReceiptToken(bytes memory) public pure virtual override returns (address) {
        return address(0);
    }

    function collateralPosition(bytes memory market) public pure virtual override returns (address) {
        return marketTarget(market);
    }

    function debtPosition(bytes memory market) public pure virtual override returns (address) {
        return marketTarget(market);
    }

    function _collateralOf(bytes memory market) internal view virtual override returns (uint256) {
        (IMorphoBlue morpho,, Id id) = _decodeMarket(market);
        (,, uint128 collateral) = morpho.position(id, address(this));
        return collateral;
    }

    /// @dev A zero oracle price can't value the debt, so it is reported as 0 (borrows then revert, other actions use the
    ///      last price)
    function _debtPriceInCollateral(bytes memory market) internal view virtual override returns (uint256) {
        (, MarketParams memory marketParams,) = _decodeMarket(market);
        uint256 price = IMorphoOracle(marketParams.oracle).price();
        if (price == 0) return 0;
        return Math.mulDiv(1e36, 1e36, price);
    }

    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IMorphoBlue morpho, MarketParams memory marketParams,) = _decodeMarket(market);
        IERC20(marketParams.collateralToken).forceApprove(address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, address(this), "");
        IERC20(marketParams.collateralToken).forceApprove(address(morpho), 0);
        return amount;
    }

    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (IMorphoBlue morpho, MarketParams memory marketParams,) = _decodeMarket(market);
        uint256 collateral = _collateralOf(market);
        withdrawn = amount > collateral ? collateral : amount;
        morpho.withdrawCollateral(marketParams, withdrawn, address(this), address(this));
    }

    function _borrow(bytes memory market, uint256 amount) internal virtual override returns (uint256 borrowed) {
        (IMorphoBlue morpho, MarketParams memory marketParams,) = _decodeMarket(market);
        (borrowed,) = morpho.borrow(marketParams, amount, 0, address(this), address(this));
    }

    function _repay(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (IMorphoBlue morpho, MarketParams memory marketParams, Id id) = _decodeMarket(market);
        uint256 debt = _debtOf(market);
        bool isFullRepay = amount >= debt;
        IERC20(marketParams.loanToken).forceApprove(address(morpho), isFullRepay ? debt : amount);
        if (isFullRepay) {
            (, uint128 borrowShares,) = morpho.position(id, address(this));
            (repaid,) = morpho.repay(marketParams, 0, borrowShares, address(this), "");
        } else {
            (repaid,) = morpho.repay(marketParams, amount, 0, address(this), "");
        }
        IERC20(marketParams.loanToken).forceApprove(address(morpho), 0);
    }
}

/// @notice Morpho Blue borrow adapter with the kit's default operations
contract AWKMorphoBlueBorrowAdapter is AWKMorphoBlueBorrowAdapterCore, AWKBorrowOperations {}
