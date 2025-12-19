// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeLedger as FeeLedger} from "./FeeLedger.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAgentWallet {
    function baseAsset() external view returns (IERC20);
    function feeLedger() external view returns (FeeLedger);
}
