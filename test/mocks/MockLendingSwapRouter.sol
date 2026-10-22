// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IUniswapV3SwapRouter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error MockLendingRouterInvalidPath();
error MockLendingRouterInsufficientOutput();

contract MockLendingSwapRouter {
    uint256 public configuredOutputAmount;
    bytes public lastPath;

    function setOutputAmount(uint256 amount) external {
        configuredOutputAmount = amount;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        bytes calldata path = params.path;
        if (path.length < 43 || (path.length - 20) % 23 != 0) revert MockLendingRouterInvalidPath();
        address tokenIn;
        address tokenOut;
        assembly {
            tokenIn := shr(96, calldataload(path.offset))
            tokenOut := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
        if (tokenIn == address(0) || tokenOut == address(0)) revert MockLendingRouterInvalidPath();
        if (configuredOutputAmount < params.amountOutMinimum) revert MockLendingRouterInsufficientOutput();
        lastPath = path;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        IERC20(tokenOut).transfer(params.recipient, configuredOutputAmount);
        return configuredOutputAmount;
    }
}
