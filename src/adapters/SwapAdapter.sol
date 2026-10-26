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
import {FeeActions} from "../fees/FeeActions.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IYieldSeekerSwapSellPolicy} from "./SwapSellPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidSlippage(uint256 maxSlippageBps);
error SwapBelowOraclePrice(uint256 received, uint256 minimum);

/**
 * @title YieldSeekerSwapAdapter
 * @notice Swap rules shared by every agent type
 * @dev Reward tokens (in the sell policy) may be swapped to the base asset. The base asset may only be swapped into a
 *      token that a fee module accounts for in this wallet (e.g. a borrowed token), at most MAX_SLIPPAGE_BPS below
 *      the price oracle and without spending base asset held back for fees. Tokens a fee module accounts for cannot
 *      be swapped away. Every swap is reported to the fee modules, which decide what it costs.
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
            if (!_isFeeModuleToken(buyToken)) revert AssetNotAllowed();
            return;
        }
        if (_isFeeModuleToken(sellToken)) revert AssetNotAllowed();
        IYieldSeekerSwapSellPolicy(SELL_POLICY).validateSellableToken(sellToken);
        _requireBaseAsset(buyToken);
    }

    /// @dev Whether a fee module (not the base asset) accounts for `token` in this wallet
    function _isFeeModuleToken(address token) internal view returns (bool) {
        if (token == _baseAssetAddress()) return false;
        (bool allowed,) = _feeTracker().withdrawReserve(address(this), token);
        return allowed;
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal virtual override returns (uint256 buyAmount, uint256 soldAmount) {
        (buyAmount, soldAmount) = super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
        if (sellToken == _baseAssetAddress()) {
            uint256 minimum = (PRICE_ORACLE.quote(sellToken, buyToken, soldAmount) * (1e4 - MAX_SLIPPAGE_BPS)) / 1e4;
            if (buyAmount < minimum) revert SwapBelowOraclePrice(buyAmount, minimum);
            (, uint256 feesReserved) = _feeTracker().withdrawReserve(address(this), sellToken);
            if (IERC20(sellToken).balanceOf(address(this)) < feesReserved) revert AWKErrors.InsufficientBalance();
        }
        _report(FeeActions.SWAP, abi.encode(sellToken, soldAmount, buyToken, buyAmount));
    }
}
