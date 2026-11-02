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

import {IAgentWalletFactory} from "../IAgentWalletFactory.sol";
import {AWKAgentWalletV3} from "../agentwalletkit/AWKAgentWalletV3.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {IYieldSeekerSwapPolicy} from "../swaps/IYieldSeekerSwapPolicy.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

error NoSwapPolicy(bytes32 agentProfile);
error FeesOwed(uint256 owed);

/**
 * @title YieldSeekerSwapAdapter
 * @notice Swap mechanics shared by every agent type; the rules come from the wallet's swap policy
 * @dev The policy is the factory's swapPolicy for the wallet's agent profile (set by the timelock): it decides which
 *      swaps are allowed and whether a finished swap is a reward sale or a trade, which is what gets reported to the
 *      fee modules. A swap that sells the base asset must leave no fees unpaid.
 */
abstract contract YieldSeekerSwapAdapter is AWKSwapAdapter, YieldSeekerAdapter {
    function _beforeSwap(address sellToken, address buyToken) internal view virtual override {
        _swapPolicy().checkSwap(address(this), sellToken, buyToken);
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal virtual override returns (uint256 buyAmount, uint256 soldAmount) {
        (buyAmount, soldAmount) = super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
        bytes32 action = _swapPolicy().checkSwapResult(address(this), sellToken, soldAmount, buyToken, buyAmount);
        _reportAction(action, abi.encode(FeeActions.Swap({sold: sellToken, soldAmount: soldAmount, bought: buyToken, boughtAmount: buyAmount})));
        if (sellToken == _baseAssetAddress()) {
            uint256 owed = _feeTracker().feesOwedInBaseAsset(address(this));
            if (owed > 0) revert FeesOwed(owed);
        }
    }

    function _swapPolicy() internal view returns (IYieldSeekerSwapPolicy policy) {
        AWKAgentWalletV3 wallet = AWKAgentWalletV3(payable(address(this)));
        bytes32 agentProfile = wallet.agentProfile();
        policy = IAgentWalletFactory(address(wallet.FACTORY())).swapPolicy(agentProfile);
        if (address(policy) == address(0)) revert NoSwapPolicy(agentProfile);
    }
}
