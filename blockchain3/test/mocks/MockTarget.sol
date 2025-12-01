// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockTarget {
    event FunctionCalled(bytes4 selector, bytes data);

    fallback() external payable {
        emit FunctionCalled(msg.sig, msg.data);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn) external payable returns (uint256) {
        emit FunctionCalled(msg.sig, msg.data);
        return amountIn;
    }

    function claim(address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) external {
        emit FunctionCalled(msg.sig, msg.data);
    }

    // 0x transformERC20 signature
    function transformERC20(
        address inputToken,
        address outputToken,
        uint256 inputTokenAmount,
        uint256 minOutputTokenAmount,
        bytes[] memory transformations
    )
        external
        payable
        returns (uint256 outputTokenAmount)
    {
        emit FunctionCalled(msg.sig, msg.data);
        return minOutputTokenAmount;
    }
}
