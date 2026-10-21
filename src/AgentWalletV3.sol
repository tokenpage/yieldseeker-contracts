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

import {YieldSeekerStorageV1} from "./AgentWalletV1.sol";
import {YieldSeekerAgentWalletV2} from "./AgentWalletV2.sol";
import {AWKAgentWalletV2} from "./agentwalletkit/AWKAgentWalletV2.sol";
import {IYieldSeekerFeeModule} from "./fees/IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerAgentWalletV3
 * @notice YieldSeekerAgentWalletV2 with two changes:
 *         1. The fee contract is set once, at creation, and never re-synced, so a factory change cannot
 *            swap the fee logic under an existing wallet.
 *         2. The fee contract decides what the owner may withdraw (reverting for tokens that may not leave), so e.g.
 *            borrow agents can withdraw borrowed assets.
 * @dev Only deploy this implementation for YieldSeekerAgentWalletFactoryV2. Wallets that already have a fee tracker
 *      would pin it, and a legacy FeeTracker has no withdrawable().
 */
contract YieldSeekerAgentWalletV3 is YieldSeekerAgentWalletV2 {
    constructor(address factory) YieldSeekerAgentWalletV2(factory) {}

    function _syncFromFactory() internal virtual override {
        if (address(YieldSeekerStorageV1.layout().feeTracker) == address(0)) {
            super._syncFromFactory();
            return;
        }
        AWKAgentWalletV2._syncFromFactory();
        emit SyncedFromFactory(address(adapterRegistry()), address(feeTracker()));
    }

    function _getWithdrawableBalance(address asset) internal view virtual override returns (uint256) {
        return IYieldSeekerFeeModule(address(feeTracker())).withdrawable(address(this), asset, IERC20(asset).balanceOf(address(this)));
    }
}
