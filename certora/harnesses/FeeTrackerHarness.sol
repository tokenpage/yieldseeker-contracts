// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeTrackerHarness is YieldSeekerFeeTracker {
    uint256 private _walletBaseAssetBalance;

    constructor() YieldSeekerFeeTracker(address(this), address(0xBEEF)) {
        _modules.push(IYieldSeekerFeeModule(address(0xCAFE)));
        _modules.push(IYieldSeekerFeeModule(address(0xFACE)));
    }

    function baseAsset() external view returns (IERC20) {
        return IERC20(address(this));
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? _walletBaseAssetBalance : 0;
    }

    function setWalletBaseAssetBalance(uint256 balance) external {
        _walletBaseAssetBalance = balance;
    }

    function moduleCount() external view returns (uint256) {
        return _modules.length;
    }
}
