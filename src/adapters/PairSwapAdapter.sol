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
import {YieldSeekerBorrowFeeModule} from "../fees/BorrowFeeModule.sol";
import {AssetNotAllowed, YieldSeekerAdapter} from "./Adapter.sol";
import {IYieldSeekerSwapSellPolicy} from "./SwapSellPolicy.sol";

error InvalidSlippage(uint256 maxSlippageBps);
error SwapBelowOraclePrice(uint256 received, uint256 minimum);

/**
 * @title YieldSeekerPairSwapAdapter
 * @notice Swap rules for borrow agents
 * @dev Two kinds of swap, both into a token the wallet needs:
 *      - Base asset -> a token the wallet has borrowed (to repay debt), at most MAX_SLIPPAGE_BPS below the oracle.
 *        The reverse direction is not allowed, so collateral cannot be churned back and forth.
 *      - Reward token in SELL_POLICY -> base asset, as in the vault swap adapters. Borrowed tokens never take this path.
 */
abstract contract YieldSeekerPairSwapAdapter is AWKSwapAdapter, YieldSeekerAdapter {
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

    function _isBorrowedToken(address token) internal view returns (bool) {
        return YieldSeekerBorrowFeeModule(address(_feeTracker())).isBorrowedToken(address(this), token);
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

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal virtual override returns (uint256 buyAmount, uint256 soldAmount) {
        (buyAmount, soldAmount) = super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
        if (sellToken != _baseAssetAddress()) return (buyAmount, soldAmount);
        uint256 minimum = (PRICE_ORACLE.quote(sellToken, buyToken, soldAmount) * (1e4 - MAX_SLIPPAGE_BPS)) / 1e4;
        if (buyAmount < minimum) revert SwapBelowOraclePrice(buyAmount, minimum);
    }
}
