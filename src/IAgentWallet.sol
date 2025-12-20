// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAgentWallet {
    function baseAsset() external view returns (IERC20);
    function feeTracker() external view returns (FeeTracker);
}
