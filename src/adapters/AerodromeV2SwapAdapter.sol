// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKAerodromeV2SwapAdapter} from "../agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {YieldSeekerSwapAdapter} from "./SwapAdapter.sol";

contract YieldSeekerAerodromeV2SwapAdapter is AWKAerodromeV2SwapAdapter, YieldSeekerSwapAdapter {
    constructor(address aerodromeV2Router, address aerodromeV2Factory) AWKAerodromeV2SwapAdapter(aerodromeV2Router, aerodromeV2Factory) {}

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
