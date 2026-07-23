// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKMoonwellRewardAdapter} from "../agentwalletkit/adapters/AWKMoonwellRewardAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract YieldSeekerMoonwellRewardAdapter is AWKMoonwellRewardAdapter, YieldSeekerAdapter {
    IERC20 public immutable WELL_TOKEN;

    constructor(address wellToken) {
        if (wellToken == address(0)) revert AWKErrors.ZeroAddress();
        WELL_TOKEN = IERC20(wellToken);
    }

    function _claimInternal(address comptroller, address holder, address[] memory mTokens) internal override {
        uint256 wellBalanceBefore = WELL_TOKEN.balanceOf(address(this));
        super._claimInternal(comptroller, holder, mTokens);
        uint256 wellBalanceAfter = WELL_TOKEN.balanceOf(address(this));
        uint256 claimed = wellBalanceAfter - wellBalanceBefore;
        if (claimed > 0) {
            _feeTracker().recordAgentYieldTokenEarned(address(WELL_TOKEN), claimed);
        }
    }
}
