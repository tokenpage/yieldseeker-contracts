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
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerMoonwellRewardAdapter
 * @notice Claims Moonwell rewards into the wallet and reports what arrived to the fee modules: WELL, and the base
 *         asset when a market also pays rewards in it
 * @dev Both amounts are measured before the first report, since a report can pay fees from the base asset.
 */
contract YieldSeekerMoonwellRewardAdapter is AWKMoonwellRewardAdapter, YieldSeekerAdapter {
    IERC20 public immutable WELL_TOKEN;

    constructor(address wellToken) {
        if (wellToken == address(0)) revert AWKErrors.ZeroAddress();
        WELL_TOKEN = IERC20(wellToken);
    }

    function _claimInternal(address comptroller, address holder, address[] memory mTokens) internal override {
        IERC20 baseAsset = _baseAsset();
        uint256 wellBalanceBefore = WELL_TOKEN.balanceOf(address(this));
        uint256 baseBalanceBefore = baseAsset.balanceOf(address(this));
        super._claimInternal(comptroller, holder, mTokens);
        uint256 wellClaimed = WELL_TOKEN.balanceOf(address(this)) - wellBalanceBefore;
        uint256 baseClaimed = address(baseAsset) == address(WELL_TOKEN) ? 0 : baseAsset.balanceOf(address(this)) - baseBalanceBefore;
        if (wellClaimed > 0) _reportAction(FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(WELL_TOKEN), amount: wellClaimed})));
        if (baseClaimed > 0) _reportAction(FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(baseAsset), amount: baseClaimed})));
    }
}
