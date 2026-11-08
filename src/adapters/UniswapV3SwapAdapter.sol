// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerSwapAdapter} from "./SwapAdapter.sol";

contract YieldSeekerUniswapV3SwapAdapter is AWKUniswapV3SwapAdapter, YieldSeekerSwapAdapter {
    constructor(address uniswapV3Router) AWKUniswapV3SwapAdapter(uniswapV3Router) {}

    function _swapOperation(
        address router,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 minBuyAmount,
        uint256 deadline,
        bytes memory route
    )
        internal
        override(AWKSwapAdapter, YieldSeekerSwapAdapter)
        returns (uint256, uint256)
    {
        return super._swapOperation(router, sellToken, buyToken, sellAmount, minBuyAmount, deadline, route);
    }
}
