// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../Errors.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract YieldSeekerZeroXAdapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    address public immutable ALLOWANCE_TARGET;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event Swapped(address indexed wallet, address indexed target, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount);

    error InvalidAllowanceTarget();
    error SwapFailed(bytes reason);
    error InsufficientOutput(uint256 received, uint256 minExpected);
    error InsufficientEth(uint256 have, uint256 need);

    constructor(address allowanceTarget_) {
        if (allowanceTarget_ == address(0)) revert InvalidAllowanceTarget();
        ALLOWANCE_TARGET = allowanceTarget_;
    }

    /**
     * @notice Override execute to handle swap operations
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.swap.selector) {
            (address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) = abi.decode(data[4:], (address, address, uint256, uint256, bytes, uint256));
            uint256 buyAmount = _swapInternal(target, sellToken, buyToken, sellAmount, minBuyAmount, swapCallData, value);
            return abi.encode(buyAmount);
        }
        revert UnknownOperation();
    }

    // ============ Swap Operations ============

    /**
     * @notice Swap tokens via 0x (public interface, should not be called directly)
     */
    function swap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes calldata swapCallData, uint256 value) external payable returns (uint256 buyAmount) {
        revert YieldSeekerErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal swap implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _swapInternal(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) internal returns (uint256 buyAmount) {
        if (sellAmount == 0 || minBuyAmount == 0) revert YieldSeekerErrors.ZeroAmount();
        _requireBaseAsset(buyToken);
        // Security: For native ETH swaps, ignore the 'value' parameter from calldata and always send exactly sellAmount.
        // This prevents a malicious operator from oversending ETH (e.g., value=10 ETH but sellAmount=1 ETH),
        // which would trap excess ETH in the 0x proxy contract. We only send what we're actually selling.
        uint256 ethToSend;
        if (sellToken == NATIVE_TOKEN) {
            ethToSend = sellAmount;
            if (address(this).balance < sellAmount) revert InsufficientEth(address(this).balance, sellAmount);
        } else {
            ethToSend = 0;
            IERC20(sellToken).forceApprove(ALLOWANCE_TARGET, sellAmount);
        }
        uint256 buyBalanceBefore = buyToken == NATIVE_TOKEN ? address(this).balance : IERC20(buyToken).balanceOf(address(this));
        uint256 sellBalanceBefore = sellToken == NATIVE_TOKEN ? address(this).balance : IERC20(sellToken).balanceOf(address(this));
        (bool success, bytes memory reason) = target.call{value: ethToSend}(swapCallData);
        if (!success) revert SwapFailed(reason);
        uint256 buyBalanceAfter = buyToken == NATIVE_TOKEN ? address(this).balance : IERC20(buyToken).balanceOf(address(this));
        uint256 sellBalanceAfter = sellToken == NATIVE_TOKEN ? address(this).balance : IERC20(sellToken).balanceOf(address(this));
        uint256 actualSellAmount = sellBalanceBefore - sellBalanceAfter;
        buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        _feeTracker().recordAgentTokenSwap(sellToken, actualSellAmount, buyAmount);
        emit Swapped(address(this), target, sellToken, buyToken, actualSellAmount, buyAmount);
    }
}
