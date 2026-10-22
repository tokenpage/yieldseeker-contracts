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

import {IYieldSeekerPriceOracle} from "../PriceOracle.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IYieldSeekerSwapSellPolicy} from "./SwapSellPolicy.sol";

error InvalidSlippage(uint256 maxSlippageBps);
error SwapBelowOraclePrice(uint256 received, uint256 minimum);

/**
 * @title YieldSeekerSwapAdapter
 * @notice Swap rules shared by vault and borrow agents
 * @dev Reward tokens may be swapped to the base asset. Base asset may only be swapped into a borrowed token, with slippage bounded by the price oracle.
 */
abstract contract YieldSeekerSwapAdapter is AWKSwapAdapter, YieldSeekerAdapter {
    address public immutable SELL_POLICY;
    IYieldSeekerPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable MAX_SLIPPAGE_BPS;

    constructor(address sellPolicy, IYieldSeekerPriceOracle priceOracle, uint256 maxSlippageBps) {
        if (sellPolicy == address(0) || address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxSlippageBps >= 1e4) revert InvalidSlippage(maxSlippageBps);
        SELL_POLICY = sellPolicy;
        PRICE_ORACLE = priceOracle;
        MAX_SLIPPAGE_BPS = maxSlippageBps;
    }

    function _beforeSwap(address sellToken, address buyToken) internal view virtual override {
        if (sellToken == _baseAssetAddress()) {
            if (!_isBorrowedToken(buyToken)) revert AssetNotAllowed();
            return;
        }
        if (_isBorrowedToken(sellToken)) revert AssetNotAllowed();
        IYieldSeekerSwapSellPolicy(SELL_POLICY).validateSellableToken(sellToken);
        _requireBaseAsset(buyToken);
    }

    function _afterSwap(address sellToken, uint256 soldAmount, uint256 buyAmount) internal virtual override {
        if (sellToken != _baseAssetAddress()) {
            _feeTracker().recordAgentTokenSwap(sellToken, soldAmount, buyAmount);
        }
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal virtual override returns (uint256 buyAmount, uint256 soldAmount) {
        (buyAmount, soldAmount) = super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
        if (sellToken != _baseAssetAddress()) return (buyAmount, soldAmount);
        uint256 minimum = (PRICE_ORACLE.quote(sellToken, buyToken, soldAmount) * (1e4 - MAX_SLIPPAGE_BPS)) / 1e4;
        if (buyAmount < minimum) revert SwapBelowOraclePrice(buyAmount, minimum);
    }
}
