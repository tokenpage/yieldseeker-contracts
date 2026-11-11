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
}

contract BorrowFeeModuleHarness is YieldSeekerBorrowFeeModule, FeeTrackerSurface {
    mapping(address wallet => mapping(address position => address)) public debtTokenForPosition;
    mapping(address wallet => mapping(address position => bool)) private _hasDebtToken;

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
}
