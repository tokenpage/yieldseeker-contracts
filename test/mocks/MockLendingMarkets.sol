// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAaveV3LendingPool} from "../../src/agentwalletkit/adapters/AWKAaveV3LendingAdapter.sol";
import {IAaveV4Spoke} from "../../src/agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {IMorphoBlue} from "../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockLendingAaveV3Pool is IAaveV3LendingPool {
    mapping(address asset => ReserveDataLegacy reserve) private _reserves;
    mapping(address user => uint256 category) private _userEMode;
    uint256 public lastRepayAmount;

    function setReserve(address asset, address aTokenAddress, address variableDebtTokenAddress) external {
        ReserveDataLegacy storage reserve = _reserves[asset];
        reserve.aTokenAddress = aTokenAddress;
        reserve.variableDebtTokenAddress = variableDebtTokenAddress;
    }

    function getReserveData(address asset) external view override returns (ReserveDataLegacy memory) {
        return _reserves[asset];
    }

    function getUserEMode(address user) external view override returns (uint256) {
        return _userEMode[user];
    }

    function setUserEMode(uint8 categoryId) external override {
        _userEMode[msg.sender] = categoryId;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockERC20(_reserves[asset].aTokenAddress).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256 withdrawn) {
        MockERC20 aToken = MockERC20(_reserves[asset].aTokenAddress);
        uint256 collateral = aToken.balanceOf(msg.sender);
        withdrawn = amount == type(uint256).max || amount > collateral ? collateral : amount;
        aToken.burn(msg.sender, withdrawn);
        IERC20(asset).transfer(to, withdrawn);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        MockERC20(_reserves[asset].variableDebtTokenAddress).mint(onBehalfOf, amount);
        MockERC20(asset).mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256 repaid) {
        MockERC20 variableDebtToken = MockERC20(_reserves[asset].variableDebtTokenAddress);
        uint256 debt = variableDebtToken.balanceOf(onBehalfOf);
        repaid = amount == type(uint256).max || amount > debt ? debt : amount;
        lastRepayAmount = repaid;
        if (repaid != 0) {
            IERC20(asset).transferFrom(onBehalfOf, address(this), repaid);
            variableDebtToken.burn(onBehalfOf, repaid);
        }
    }

    function growDebt(address asset, address user, uint256 amount) external {
        MockERC20(_reserves[asset].variableDebtTokenAddress).mint(user, amount);
    }

    function reduceDebt(address asset, address user, uint256 amount) external {
        MockERC20 variableDebtToken = MockERC20(_reserves[asset].variableDebtTokenAddress);
        uint256 debt = variableDebtToken.balanceOf(user);
        variableDebtToken.burn(user, amount > debt ? debt : amount);
    }
}

contract MockLendingMorpho is IMorphoBlue {
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct MarketState {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    mapping(bytes32 marketId => mapping(address user => Position position_)) private _positions;
    mapping(bytes32 marketId => MarketState state) private _markets;

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory) external override {
        IERC20(marketParams.collateralToken).transferFrom(msg.sender, address(this), assets);
        _positions[keccak256(abi.encode(marketParams))][onBehalf].collateral += uint128(assets);
    }

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver) external override {
        Position storage position_ = _positions[keccak256(abi.encode(marketParams))][onBehalf];
        uint256 withdrawn = assets > position_.collateral ? position_.collateral : assets;
        position_.collateral -= uint128(withdrawn);
        IERC20(marketParams.collateralToken).transfer(receiver, withdrawn);
    }

    function borrow(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver) external override returns (uint256 assetsBorrowed, uint256 sharesBorrowed) {
        bytes32 id = keccak256(abi.encode(marketParams));
        MarketState storage market_ = _markets[id];
        Position storage position_ = _positions[id][onBehalf];
        if (shares == 0) {
            assetsBorrowed = assets;
            sharesBorrowed = Math.mulDiv(assets, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, Math.Rounding.Ceil);
        } else {
            sharesBorrowed = shares;
            assetsBorrowed = Math.mulDiv(shares, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
        }
        position_.borrowShares += uint128(sharesBorrowed);
        market_.totalBorrowAssets += uint128(assetsBorrowed);
        market_.totalBorrowShares += uint128(sharesBorrowed);
        MockERC20(marketParams.loanToken).mint(receiver, assetsBorrowed);
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory) external override returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        bytes32 id = keccak256(abi.encode(marketParams));
        MarketState storage market_ = _markets[id];
        Position storage position_ = _positions[id][onBehalf];
        uint256 debt = _sharesToAssetsUp(market_, position_.borrowShares);
        if (shares != 0) {
            sharesRepaid = shares > position_.borrowShares ? position_.borrowShares : shares;
            assetsRepaid = sharesRepaid == position_.borrowShares ? debt : Math.mulDiv(sharesRepaid, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
        } else {
            assetsRepaid = assets > debt ? debt : assets;
            sharesRepaid = assetsRepaid == debt ? position_.borrowShares : Math.mulDiv(assetsRepaid, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, Math.Rounding.Ceil);
            if (sharesRepaid > position_.borrowShares) sharesRepaid = position_.borrowShares;
        }
        if (assetsRepaid != 0) IERC20(marketParams.loanToken).transferFrom(onBehalf, address(this), assetsRepaid);
        position_.borrowShares -= uint128(sharesRepaid);
        market_.totalBorrowAssets -= uint128(assetsRepaid);
        market_.totalBorrowShares -= uint128(sharesRepaid);
    }

    function accrueInterest(MarketParams memory) external override {}

    function position(bytes32 id, address user) external view override returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral) {
        Position storage position_ = _positions[id][user];
        return (position_.supplyShares, position_.borrowShares, position_.collateral);
    }

    function market(bytes32 id) external view override returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee) {
        MarketState storage market_ = _markets[id];
        return (market_.totalSupplyAssets, market_.totalSupplyShares, market_.totalBorrowAssets, market_.totalBorrowShares, market_.lastUpdate, market_.fee);
    }

    function _sharesToAssetsUp(MarketState storage market_, uint256 shares) private view returns (uint256) {
        if (shares == 0) return 0;
        return Math.mulDiv(shares, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }
}

contract MockLendingAaveV4Spoke is IAaveV4Spoke {
    mapping(uint256 reserveId => Reserve reserve_) private _reserves;
    mapping(uint256 reserveId => mapping(address user => uint256 amount)) private _supplied;
    mapping(uint256 reserveId => mapping(address user => uint256 amount)) private _debt;
    mapping(uint256 reserveId => mapping(address user => bool enabled)) public usingAsCollateral;

    function setReserve(uint256 reserveId, address underlying, uint8 decimals_) external {
        _reserves[reserveId] = Reserve({underlying: underlying, hub: address(0), assetId: uint16(reserveId), decimals: decimals_, collateralRisk: 0, flags: 0, dynamicConfigKey: 0});
    }

    function getReserve(uint256 reserveId) external view override returns (Reserve memory) {
        return _reserves[reserveId];
    }

    function getUserSuppliedAssets(uint256 reserveId, address user) external view override returns (uint256) {
        return _supplied[reserveId][user];
    }

    function getUserTotalDebt(uint256 reserveId, address user) external view override returns (uint256) {
        return _debt[reserveId][user];
    }

    function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external override returns (uint256, uint256) {
        IERC20(_reserves[reserveId].underlying).transferFrom(msg.sender, address(this), amount);
        _supplied[reserveId][onBehalfOf] += amount;
        return (amount, amount);
    }

    function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) external override returns (uint256, uint256) {
        uint256 supplied = _supplied[reserveId][onBehalfOf];
        uint256 withdrawn = amount > supplied ? supplied : amount;
        _supplied[reserveId][onBehalfOf] = supplied - withdrawn;
        IERC20(_reserves[reserveId].underlying).transfer(onBehalfOf, withdrawn);
        return (withdrawn, withdrawn);
    }

    function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external override returns (uint256, uint256) {
        _debt[reserveId][onBehalfOf] += amount;
        MockERC20(_reserves[reserveId].underlying).mint(onBehalfOf, amount);
        return (amount, amount);
    }

    function repay(uint256 reserveId, uint256 amount, address onBehalfOf) external override returns (uint256, uint256) {
        uint256 debt = _debt[reserveId][onBehalfOf];
        uint256 repaid = amount > debt ? debt : amount;
        if (repaid != 0) IERC20(_reserves[reserveId].underlying).transferFrom(onBehalfOf, address(this), repaid);
        _debt[reserveId][onBehalfOf] = debt - repaid;
        return (repaid, repaid);
    }

    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral_, address onBehalfOf) external override {
        usingAsCollateral[reserveId][onBehalfOf] = usingAsCollateral_;
    }
}
