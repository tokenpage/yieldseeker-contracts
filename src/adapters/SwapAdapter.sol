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
pragma solidity 0.8.38;

import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {IYieldSeekerSwapPolicy} from "../swaps/IYieldSeekerSwapPolicy.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

error NoSwapPolicy();
error FeesOwed(uint256 owed);

/**
 * @title YieldSeekerSwapAdapter
 * @notice Swap mechanics shared by every agent type; the rules come from the wallet's swap policy
 * @dev The policy is the wallet's swapPolicy (its agent profile's, set in the factory by the timelock and copied at
 *      sync): it decides which swaps are allowed and whether a finished swap is a reward sale or a trade, which is
 *      what gets reported to the fee modules. A swap that sells the base asset must leave no fees unpaid.
 */
abstract contract YieldSeekerSwapAdapter is AWKSwapAdapter, YieldSeekerAdapter {
    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal virtual override returns (uint256 soldAmount, uint256 buyAmount) {
        IYieldSeekerSwapPolicy policy = _swapPolicy();
        policy.checkSwap(address(this), sellToken, buyToken);
        (soldAmount, buyAmount) = super._swapOperation(router, sellToken, buyToken, sellAmount, minBuyAmount, deadline, route);
        bytes32 action = policy.checkSwapResult(address(this), sellToken, soldAmount, buyToken, buyAmount);
        _reportAction(action, abi.encode(FeeActions.Swap({sold: sellToken, soldAmount: soldAmount, bought: buyToken, boughtAmount: buyAmount})));
        if (sellToken == _baseAssetAddress()) {
            uint256 owed = _feeTracker().feesOwedInBaseAsset(address(this));
            if (owed > 0) revert FeesOwed(owed);
        }
    }

    function _swapPolicy() internal view returns (IYieldSeekerSwapPolicy policy) {
        policy = _ysAgentWallet().swapPolicy();
        if (address(policy) == address(0)) revert NoSwapPolicy();
    }
}
