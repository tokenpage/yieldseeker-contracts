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

import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKWalletLinkRegistry} from "../agentwalletkit/AWKWalletLinkRegistry.sol";
import {AWKTransferAdapter} from "../agentwalletkit/adapters/AWKTransferAdapter.sol";
import {IYieldSeekerFeeModule} from "../fees/IYieldSeekerFeeModule.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerTransferAdapter
 * @notice Move a token between two linked agent wallets of the same owner
 * @dev Both wallets' fee contracts must allow the token to leave them (each reverts for tokens it does not allow),
 *      so the receiver can always withdraw what it gets, and the sender can only move what its owner could
 *      withdraw, so fees owed stay behind.
 */
contract YieldSeekerTransferAdapter is AWKTransferAdapter, YieldSeekerAdapter {
    constructor(AWKWalletLinkRegistry linkRegistry) AWKTransferAdapter(linkRegistry) {}

    function _beforeTransfer(address token, address to, uint256 amount) internal view override {
        IYieldSeekerFeeModule(address(IAgentWallet(to).feeTracker())).withdrawable(to, token, 0);
        uint256 withdrawable = IYieldSeekerFeeModule(address(_feeTracker())).withdrawable(address(this), token, IERC20(token).balanceOf(address(this)));
        if (amount > withdrawable) revert AWKErrors.InsufficientBalance();
    }
}
