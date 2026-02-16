// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidSwapTokenAddress(address token);
error InvalidSwapRoute();
error InvalidRouteLength(uint256 length);
error InvalidRouteEndpoints(address expectedSellToken, address expectedBuyToken);
error InsufficientOutput(uint256 received, uint256 minimum);

/**
 * @title AWKSwapAdapter
 * @notice Base class for swap adapters
 * @dev Swap execution runs via delegatecall from AgentWallet.
 */
abstract contract AWKSwapAdapter is AWKAdapter {
    struct SwapBalanceSnapshot {
        uint256 buyBalanceBefore;
        uint256 sellBalanceBefore;
    }

    event Swapped(address indexed wallet, address indexed router, address sellToken, address buyToken, uint256 soldAmount, uint256 buyAmount);

    // ============ Shared Swap Helpers ============

    function _beforeSwap(address sellToken, address buyToken) internal view virtual {}

    function _afterSwap(address sellToken, uint256 soldAmount, uint256 buyAmount) internal virtual {}

    function _validateRouteEndpoints(address sellToken, address buyToken, address routeStartToken, address routeEndToken) internal pure {
        if (routeStartToken != sellToken || routeEndToken != buyToken) revert InvalidRouteEndpoints(sellToken, buyToken);
    }

    function _beforeSwapInternal(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) internal virtual returns (SwapBalanceSnapshot memory snapshot) {
        if (sellToken == address(0) || buyToken == address(0) || sellToken == buyToken) revert InvalidSwapTokenAddress(sellToken);
        if (sellAmount == 0 || minBuyAmount == 0) revert AWKErrors.ZeroAmount();
        _beforeSwap(sellToken, buyToken);
        snapshot.buyBalanceBefore = IERC20(buyToken).balanceOf(address(this));
        snapshot.sellBalanceBefore = IERC20(sellToken).balanceOf(address(this));
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal virtual returns (uint256 buyAmount, uint256 soldAmount) {
        uint256 buyBalanceAfter = IERC20(buyToken).balanceOf(address(this));
        uint256 sellBalanceAfter = IERC20(sellToken).balanceOf(address(this));
        soldAmount = snapshot.sellBalanceBefore - sellBalanceAfter;
        buyAmount = buyBalanceAfter - snapshot.buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        _afterSwap(sellToken, soldAmount, buyAmount);
        emit Swapped(address(this), router, sellToken, buyToken, soldAmount, buyAmount);
    }
}
