// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFeeModuleAction {
    function onAction(address wallet, bytes32 action, bytes calldata data, uint256 maxPayment) external returns (uint256);
}

abstract contract FeeTrackerSurface {
    uint256 public planRateBps = 10_000;

    function walletPlan(address, bytes32) external view returns (bytes memory) {
        return abi.encode(planRateBps);
    }

    function setPlanRate(uint256 rateBps) external {
        require(rateBps <= 10_000);
        planRateBps = rateBps;
    }

    function baseAsset() external pure returns (IERC20) {
        return IERC20(address(0xBEEF));
    }

    function reportAction(bytes32 action, bytes calldata data, uint256 maxPayment) external virtual returns (uint256) {
        return IFeeModuleAction(address(this)).onAction(msg.sender, action, data, maxPayment);
    }
}

contract YieldFeeModuleHarness is YieldSeekerYieldFeeModule, FeeTrackerSurface {
    constructor() YieldSeekerYieldFeeModule(YieldSeekerFeeTracker(address(this)), 10_000) {}

    function reachFeeChargeAndPayment() external returns (uint256) {
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: address(0xCAFE), spent: 0, heldBefore: 0, assetsOut: 1});
        return this.reportAction(keccak256("withdraw"), abi.encode(withdrawal), 1);
    }

    function reportFullWithdrawal(address target, uint256 heldBefore, uint256 assetsOut) external {
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: target, spent: heldBefore, heldBefore: heldBefore, assetsOut: assetsOut});
        this.reportAction(FeeActions.WITHDRAW, abi.encode(withdrawal), 0);
    }

    function reportWithdrawal(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) external {
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: target, spent: spent, heldBefore: heldBefore, assetsOut: assetsOut});
        this.reportAction(FeeActions.WITHDRAW, abi.encode(withdrawal), 0);
    }

    function reportDeposit(address target, uint256 assetsIn) external {
        this.reportAction(FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: target, assetsIn: assetsIn})), 0);
    }

    function reportClaim(address token, uint256 amount) external {
        this.reportAction(FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: token, amount: amount})), 0);
    }

    function reportRewardSale(address sold, uint256 soldAmount, address bought, uint256 boughtAmount) external {
        this.reportAction(FeeActions.REWARD_SALE, abi.encode(FeeActions.Swap({sold: sold, soldAmount: soldAmount, bought: bought, boughtAmount: boughtAmount})), 0);
    }

    function isValidRate(uint256 rateBps) external view returns (bool) {
        return this.isValidPlan(abi.encode(rateBps));
    }
}

contract BorrowFeeModuleHarness is YieldSeekerBorrowFeeModule, FeeTrackerSurface {
    mapping(address wallet => mapping(address position => address)) public debtTokenForPosition;
    mapping(address wallet => mapping(address position => bool)) private _hasDebtToken;
    address public constant WITNESS_MARKET = address(0xCAFE);
    address public constant WITNESS_DEBT_TOKEN = address(0xBEEF);

    constructor() YieldSeekerBorrowFeeModule(YieldSeekerFeeTracker(address(this)), 10_000) {}

    function reportAction(bytes32 action, bytes calldata data, uint256 maxPayment) external override returns (uint256) {
        if (action == keccak256("debtChange")) {
            FeeActions.DebtChange memory change = abi.decode(data, (FeeActions.DebtChange));
            address wallet = msg.sender;
            if (_hasDebtToken[wallet][change.market]) {
                require(debtTokenForPosition[wallet][change.market] == change.debtToken);
            } else {
                _hasDebtToken[wallet][change.market] = true;
                debtTokenForPosition[wallet][change.market] = change.debtToken;
            }
        }
        return IFeeModuleAction(address(this)).onAction(msg.sender, action, data, maxPayment);
    }

    function hasConsistentDebtToken(address wallet, bytes32 action, bytes calldata data) external view returns (bool) {
        if (action != keccak256("debtChange")) return true;
        FeeActions.DebtChange memory change = abi.decode(data, (FeeActions.DebtChange));
        return _hasDebtToken[wallet][change.market] && debtTokenForPosition[wallet][change.market] == change.debtToken;
    }

    function reachDebtChange() external returns (uint128 lastDebtBefore, uint128 lastDebtAfter, uint256 tokenDebtBefore, uint256 tokenDebtAfter) {
        address wallet = address(this);
        address market = WITNESS_MARKET;
        address debtToken = WITNESS_DEBT_TOKEN;
        DebtPosition storage position = debtPositions[wallet][market];
        require(position.lastDebt == 0 && tokenDebt[wallet][debtToken] == 0);

        debtTokenForPosition[wallet][market] = debtToken;
        _hasDebtToken[wallet][market] = true;
        lastDebtBefore = position.lastDebt;
        tokenDebtBefore = tokenDebt[wallet][debtToken];
        FeeActions.DebtChange memory change = FeeActions.DebtChange({market: market, debtToken: debtToken, debtBefore: 0, borrowed: 1, repaid: 0, debtPriceInBaseAsset: 1e36});
        this.reportAction(keccak256("debtChange"), abi.encode(change), 0);
        lastDebtAfter = position.lastDebt;
        tokenDebtAfter = tokenDebt[wallet][debtToken];
    }

    function reportCheckpoint(address market, address debtToken, uint256 debtBefore, uint256 price) external {
        FeeActions.DebtChange memory change = FeeActions.DebtChange({market: market, debtToken: debtToken, debtBefore: debtBefore, borrowed: 0, repaid: 0, debtPriceInBaseAsset: price});
        this.reportAction(FeeActions.DEBT_CHANGE, abi.encode(change), 0);
    }

    function reportNonDebtAction(bytes32 action, bytes calldata data) external {
        require(action != FeeActions.DEBT_CHANGE);
        this.reportAction(action, data, 0);
    }
}

