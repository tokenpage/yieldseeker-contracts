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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMorphoBlue {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver) external;
    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function accrueInterest(MarketParams memory marketParams) external;
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id) external view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee);
}

/**
 * @title AWKMorphoBlueLendingAdapter
 * @notice Borrow against collateral on a Morpho Blue market
 * @dev market = abi.encode(address morpho, IMorphoBlue.MarketParams). Full repays go by shares so no interest dust is left.
 */
contract AWKMorphoBlueLendingAdapter is AWKLendingAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    function _decodeMarket(bytes memory market) internal pure returns (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams, bytes32 id) {
        (morpho, marketParams) = abi.decode(market, (IMorphoBlue, IMorphoBlue.MarketParams));
        id = keccak256(abi.encode(marketParams));
    }

    function _marketAssets(bytes memory market) internal view virtual override returns (address collateralAsset, address debtAsset) {
        (, IMorphoBlue.MarketParams memory marketParams,) = _decodeMarket(market);
        return (marketParams.collateralToken, marketParams.loanToken);
    }

    function _debtOf(bytes memory market) internal virtual override returns (uint256) {
        (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams, bytes32 id) = _decodeMarket(market);
        morpho.accrueInterest(marketParams);
        (, uint128 borrowShares,) = morpho.position(id, address(this));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(id);
        return Math.mulDiv(borrowShares, uint256(totalBorrowAssets) + VIRTUAL_ASSETS, uint256(totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function _supplyCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256) {
        (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams,) = _decodeMarket(market);
        IERC20(marketParams.collateralToken).forceApprove(address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, address(this), "");
        IERC20(marketParams.collateralToken).forceApprove(address(morpho), 0);
        return amount;
    }

    function _withdrawCollateral(bytes memory market, uint256 amount) internal virtual override returns (uint256 withdrawn) {
        (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams, bytes32 id) = _decodeMarket(market);
        (,, uint128 collateral) = morpho.position(id, address(this));
        withdrawn = amount > collateral ? collateral : amount;
        morpho.withdrawCollateral(marketParams, withdrawn, address(this), address(this));
    }

    function _borrow(bytes memory market, uint256 amount) internal virtual override returns (uint256 borrowed) {
        (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams,) = _decodeMarket(market);
        (borrowed,) = morpho.borrow(marketParams, amount, 0, address(this), address(this));
    }

    function _repay(bytes memory market, uint256 amount) internal virtual override returns (uint256 repaid) {
        (IMorphoBlue morpho, IMorphoBlue.MarketParams memory marketParams, bytes32 id) = _decodeMarket(market);
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
