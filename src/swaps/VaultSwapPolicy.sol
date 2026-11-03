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
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {IAgentWallet} from "../IAgentWallet.sol";
import {IYieldSeekerSwapSellPolicy} from "../adapters/SwapSellPolicy.sol";
import {AWKAgentWalletV3} from "../agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {IYieldSeekerSwapPolicy, SwapNotAllowed} from "./IYieldSeekerSwapPolicy.sol";

/**
 * @title YieldSeekerVaultSwapPolicy
 * @notice Vault agents only sell reward tokens (those in the sell policy) for the base asset
 * @dev Every swap is a reward sale, so the yield fee charges the base asset received. A token the wallet's registry
 *      lists as a target (a vault share, an aToken, a Comet or cToken position) is a position, never a reward, so it
 *      can't be sold whatever the sell policy allows.
 */
contract YieldSeekerVaultSwapPolicy is IYieldSeekerSwapPolicy {
    IYieldSeekerSwapSellPolicy public immutable SELL_POLICY;

    constructor(IYieldSeekerSwapSellPolicy sellPolicy) {
        if (address(sellPolicy) == address(0)) revert AWKErrors.ZeroAddress();
        SELL_POLICY = sellPolicy;
    }

    function checkSwap(address wallet, address sellToken, address buyToken) public view virtual {
        _checkRewardSale(wallet, sellToken, buyToken);
    }

    function checkSwapResult(address, address, uint256, address, uint256) public view virtual returns (bytes32) {
        return FeeActions.REWARD_SALE;
    }

    function _checkRewardSale(address wallet, address sellToken, address buyToken) internal view {
        address baseAsset = address(IAgentWallet(wallet).baseAsset());
        if (sellToken == baseAsset || buyToken != baseAsset) revert SwapNotAllowed(sellToken, buyToken);
        if (AWKAgentWalletV3(payable(wallet)).adapterRegistry().getTargetAdapter(sellToken) != address(0)) revert SwapNotAllowed(sellToken, buyToken);
        SELL_POLICY.validateSellableToken(sellToken);
    }
}
