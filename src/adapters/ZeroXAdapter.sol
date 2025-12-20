// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YieldSeekerZeroXAdapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    address public immutable ALLOWANCE_TARGET;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event Swapped(address indexed wallet, address indexed target, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount);

    error ZeroAmount();
    error InvalidAllowanceTarget();
    error SwapFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 minExpected);
    error InsufficientEth(uint256 have, uint256 need);
    error UnknownOperation();

    constructor(address allowanceTarget_) {
        if (allowanceTarget_ == address(0)) revert InvalidAllowanceTarget();
        ALLOWANCE_TARGET = allowanceTarget_;
    }

    // ============ Standard Adapter Entry Point ============

    /**
     * @notice Standard entry point for all adapter logic
     * @param target The 0x Exchange Proxy address
     * @param data The operation data (encoded swap call)
     */
    function execute(address target, bytes calldata data) external payable override returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.swap.selector) {
            (address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) = abi.decode(data[4:], (address, address, uint256, uint256, bytes, uint256));
            uint256 buyAmount = _swap(target, sellToken, buyToken, sellAmount, minBuyAmount, swapCallData, value);
            return abi.encode(buyAmount);
        }
        revert UnknownOperation();
    }

    // ============ Swap Operations (Internal) ============

    function swap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes calldata swapCallData, uint256 value) external payable returns (uint256 buyAmount) {
        revert("Use execute");
    }

    function _swap(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) internal returns (uint256 buyAmount) {
        if (sellAmount == 0 || minBuyAmount == 0) revert ZeroAmount();
        _requireBaseAsset(buyToken);
        if (sellToken == NATIVE_TOKEN) {
            // Ensure wallet has enough ETH to forward; do not rely on msg.value
            if (value < sellAmount) revert ZeroAmount();
            if (address(this).balance < value) revert InsufficientEth(address(this).balance, value);
        } else {
            IERC20(sellToken).forceApprove(ALLOWANCE_TARGET, sellAmount);
        }
        uint256 buyBalanceBefore = buyToken == NATIVE_TOKEN ? address(this).balance : IERC20(buyToken).balanceOf(address(this));
        (bool success, bytes memory reason) = target.call{value: value}(swapCallData);
        if (!success) revert SwapFailed(reason);
        uint256 buyBalanceAfter = buyToken == NATIVE_TOKEN ? address(this).balance : IERC20(buyToken).balanceOf(address(this));
        buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        emit Swapped(address(this), target, sellToken, buyToken, sellAmount, buyAmount);
    }
}
