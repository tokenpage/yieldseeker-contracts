// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IMorphoBlue, IMorphoOracle} from "../../../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperatorHostileToken is ERC20 {
    constructor() ERC20("Operator Hostile Token", "OHT") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function trySteal(address ownerAsset, address wallet, address recipient, uint256 amount) external returns (bool success) {
        bytes memory result;
        (success, result) = ownerAsset.call(abi.encodeCall(IERC20.transferFrom, (wallet, recipient, amount)));
        if (!success || result.length < 32) return false;
        success = abi.decode(result, (bool));
    }
}

contract OperatorHostileRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    bool public reached;
    address public immutable thief;

    constructor(address thief_) {
        thief = thief_;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        reached = true;
        address sellToken;
        bytes calldata path = params.path;
        assembly {
            sellToken := shr(96, calldataload(path.offset))
        }
        IERC20(sellToken).transferFrom(msg.sender, thief, params.amountIn);
        return type(uint256).max;
    }
}

contract OperatorHostileVault {
    IERC20 public immutable asset;
    bool public reached;
    address public immutable thief;

    constructor(IERC20 asset_, address thief_) {
        asset = asset_;
        thief = thief_;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        reached = true;
        asset.transferFrom(msg.sender, thief, amount);
        return amount;
    }

    function redeem(uint256 shares, address, address) external returns (uint256) {
        reached = true;
        asset.transfer(thief, shares);
        return shares;
    }
}

contract OperatorThiefReceiver {
    receive() external payable {}
}

contract OperatorMockEntryPoint {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address account => mapping(uint192 key => uint256 nonce)) private _nonces;

    function depositTo(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function getNonce(address account, uint192 key) external view returns (uint256) {
        return _nonces[account][key];
    }

    function withdrawTo(address payable recipient, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient deposit");
        balanceOf[msg.sender] -= amount;
        (bool success,) = recipient.call{value: amount}("");
        require(success, "withdraw failed");
    }
}

contract OperatorMorphoBlueMarket is IMorphoBlue {
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;
    uint256 private constant YEAR = 365 days;
    uint256 private constant WAD = 1e18;
    uint256 private constant INTEREST_RATE_BPS = 500;
    uint256 private constant MAX_LIQUIDATION_INCENTIVE = 1.15e18;

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

    error PositionHealthy();
    error PositionUnhealthy();
    error Unauthorized();
    error InvalidLiquidationAmount();
    error InsufficientCollateral();

    function supplyCollateral(MarketParams memory params, uint256 assets, address onBehalf, bytes memory) external override {
        _accrueInterest(params);
        require(IERC20(params.collateralToken).transferFrom(msg.sender, address(this), assets));
        _positions[_marketId(params)][onBehalf].collateral += uint128(assets);
    }

    function withdrawCollateral(MarketParams memory params, uint256 assets, address onBehalf, address receiver) external override {
        if (msg.sender != onBehalf) revert Unauthorized();
        _accrueInterest(params);
        Position storage position_ = _positions[_marketId(params)][onBehalf];
        uint256 withdrawn = assets > position_.collateral ? position_.collateral : assets;
        uint256 remainingCollateral = uint256(position_.collateral) - withdrawn;
        if (!_isHealthy(params, position_, remainingCollateral)) revert PositionUnhealthy();
        position_.collateral = uint128(remainingCollateral);
        require(IERC20(params.collateralToken).transfer(receiver, withdrawn));
    }

    function borrow(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, address receiver) external override returns (uint256 assetsBorrowed, uint256 sharesBorrowed) {
        if (msg.sender != onBehalf) revert Unauthorized();
        _accrueInterest(params);
        bytes32 id = _marketId(params);
        MarketState storage market_ = _markets[id];
        Position storage position_ = _positions[id][onBehalf];
        if (shares == 0) {
            assetsBorrowed = assets;
            sharesBorrowed = Math.mulDiv(assets, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, Math.Rounding.Ceil);
        } else {
            sharesBorrowed = shares;
            assetsBorrowed = Math.mulDiv(shares, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
        }
        uint256 nextShares = uint256(position_.borrowShares) + sharesBorrowed;
        if (!_isHealthy(params, position_, position_.collateral, nextShares, uint256(market_.totalBorrowAssets) + assetsBorrowed, uint256(market_.totalBorrowShares) + sharesBorrowed)) {
            revert PositionUnhealthy();
        }
        position_.borrowShares = uint128(nextShares);
        market_.totalBorrowAssets += uint128(assetsBorrowed);
        market_.totalBorrowShares += uint128(sharesBorrowed);
        require(IERC20(params.loanToken).transfer(receiver, assetsBorrowed));
    }

    function repay(MarketParams memory params, uint256 assets, uint256 shares, address onBehalf, bytes memory) external override returns (uint256 assetsRepaid, uint256 sharesRepaid) {
        _accrueInterest(params);
        bytes32 id = _marketId(params);
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
        if (assetsRepaid != 0) require(IERC20(params.loanToken).transferFrom(msg.sender, address(this), assetsRepaid));
        position_.borrowShares -= uint128(sharesRepaid);
        market_.totalBorrowAssets -= uint128(assetsRepaid);
        market_.totalBorrowShares -= uint128(sharesRepaid);
    }

    function accrueInterest(MarketParams memory params) external override {
        _accrueInterest(params);
    }

    function liquidate(MarketParams calldata params, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes calldata) external returns (uint256 repaidAssets, uint256 seizedCollateral) {
        _accrueInterest(params);
        bytes32 id = _marketId(params);
        MarketState storage market_ = _markets[id];
        Position storage position_ = _positions[id][borrower];
        if (_isHealthy(params, position_, position_.collateral)) revert PositionHealthy();

        uint256 availableShares = position_.borrowShares;
        uint256 debt = _sharesToAssetsUp(market_, availableShares);
        if (repaidShares != 0 && seizedAssets != 0) revert InvalidLiquidationAmount();
        bool repayByShares = repaidShares != 0;
        if (repayByShares) {
            uint256 sharesToRepay = repaidShares > availableShares ? availableShares : repaidShares;
            repaidAssets = sharesToRepay == availableShares ? debt : Math.mulDiv(sharesToRepay, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
            repaidShares = sharesToRepay;
            uint256 collateralValue = Math.mulDiv(repaidAssets, liquidationIncentiveFactor(params.lltv), WAD, Math.Rounding.Ceil);
            seizedCollateral = Math.mulDiv(collateralValue, 1e36, IMorphoOracle(params.oracle).price(), Math.Rounding.Ceil);
        } else if (seizedAssets != 0) {
            seizedCollateral = seizedAssets > position_.collateral ? position_.collateral : seizedAssets;
            uint256 loanValue = Math.mulDiv(seizedCollateral, IMorphoOracle(params.oracle).price(), 1e36);
            repaidAssets = Math.mulDiv(loanValue, WAD, liquidationIncentiveFactor(params.lltv));
            if (repaidAssets > debt) repaidAssets = debt;
            repaidShares = repaidAssets == debt ? availableShares : Math.mulDiv(repaidAssets, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, Math.Rounding.Ceil);
            if (repaidShares > availableShares) repaidShares = availableShares;
        } else {
            revert InvalidLiquidationAmount();
        }
        if (seizedCollateral > position_.collateral) revert InsufficientCollateral();
        require(IERC20(params.loanToken).transferFrom(msg.sender, address(this), repaidAssets));
        position_.borrowShares -= uint128(repaidShares);
        position_.collateral -= uint128(seizedCollateral);
        market_.totalBorrowAssets -= uint128(repaidAssets);
        market_.totalBorrowShares -= uint128(repaidShares);
        require(IERC20(params.collateralToken).transfer(msg.sender, seizedCollateral));
    }

    function position(bytes32 id, address user) external view override returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral) {
        Position storage position_ = _positions[id][user];
        return (position_.supplyShares, position_.borrowShares, position_.collateral);
    }

    function market(bytes32 id) external view override returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee) {
        MarketState storage market_ = _markets[id];
        return (market_.totalSupplyAssets, market_.totalSupplyShares, market_.totalBorrowAssets, market_.totalBorrowShares, market_.lastUpdate, market_.fee);
    }

    function liquidationIncentiveFactor(uint256 lltv) public pure returns (uint256) {
        uint256 denominator = Math.mulDiv(lltv, 3, 10) + 7e17;
        uint256 factor = Math.mulDiv(1e36, 1, denominator);
        return factor > MAX_LIQUIDATION_INCENTIVE ? MAX_LIQUIDATION_INCENTIVE : factor;
    }

    function _accrueInterest(MarketParams memory params) private {
        MarketState storage market_ = _markets[_marketId(params)];
        uint256 lastUpdate = market_.lastUpdate;
        if (lastUpdate == 0) {
            market_.lastUpdate = uint128(block.timestamp);
            return;
        }
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return;
        uint256 interest = Math.mulDiv(market_.totalBorrowAssets, INTEREST_RATE_BPS * elapsed, 10_000 * YEAR);
        if (interest != 0) {
            market_.totalBorrowAssets += uint128(interest);
            market_.totalSupplyAssets += uint128(interest);
        }
        market_.lastUpdate = uint128(block.timestamp);
    }

    function _isHealthy(MarketParams memory params, Position storage position_, uint256 collateral) private view returns (bool) {
        MarketState storage market_ = _markets[_marketId(params)];
        return _isHealthy(params, position_, collateral, position_.borrowShares, market_.totalBorrowAssets, market_.totalBorrowShares);
    }

    function _isHealthy(MarketParams memory params, Position storage position_, uint256 collateral, uint256 borrowShares, uint256 totalBorrowAssets, uint256 totalBorrowShares) private view returns (bool) {
        if (borrowShares == 0) return true;
        uint256 price = IMorphoOracle(params.oracle).price();
        if (price == 0) return false;
        uint256 debt = Math.mulDiv(borrowShares, totalBorrowAssets + VIRTUAL_ASSETS, totalBorrowShares + VIRTUAL_SHARES, Math.Rounding.Ceil);
        uint256 collateralValue = Math.mulDiv(collateral, price, 1e36);
        uint256 borrowLimit = Math.mulDiv(collateralValue, params.lltv, WAD);
        return debt <= borrowLimit;
    }

    function _sharesToAssetsUp(MarketState storage market_, uint256 shares) private view returns (uint256) {
        if (shares == 0) return 0;
        return Math.mulDiv(shares, uint256(market_.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(market_.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
    }

    function _marketId(MarketParams memory params) private pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
