// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YieldSeekerZeroExAdapter {
    using SafeERC20 for IERC20;

    address public immutable ALLOWANCE_TARGET;

    event Swapped(address indexed wallet, address indexed target, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount, address recipient);

    error ZeroAmount();
    error InvalidRecipient();
    error InvalidAllowanceTarget();
    error SwapFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 minExpected);

    constructor(address allowanceTarget_) {
        if (allowanceTarget_ == address(0)) revert InvalidAllowanceTarget();
        ALLOWANCE_TARGET = allowanceTarget_;
    }

    function swap(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, address recipient, bytes calldata swapCallData, uint256 value) external payable returns (uint256 buyAmount) {
        // NOTE: Future enhancement - We can access baseAsset via delegatecall context:
        // IERC20 baseAsset = IAgentWallet(address(this)).baseAsset();
        // Then enforce: require(buyToken == address(baseAsset) || sellToken == address(baseAsset), "Must involve base asset");
        if (sellAmount == 0 || minBuyAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        IERC20(sellToken).forceApprove(ALLOWANCE_TARGET, sellAmount);
        uint256 buyBalanceBefore = IERC20(buyToken).balanceOf(address(this));
        (bool success, bytes memory reason) = target.call{value: value}(swapCallData);
        if (!success) revert SwapFailed(reason);
        uint256 buyBalanceAfter = IERC20(buyToken).balanceOf(address(this));
        buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        if (recipient != address(this) && buyAmount != 0) IERC20(buyToken).safeTransfer(recipient, buyAmount);
        emit Swapped(address(this), target, sellToken, buyToken, sellAmount, buyAmount, recipient);
    }
}
