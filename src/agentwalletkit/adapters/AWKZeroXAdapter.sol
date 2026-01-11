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

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidAllowanceTarget();
error InsufficientEth(uint256 balance, uint256 required);
error SwapFailed(bytes reason);
error InsufficientOutput(uint256 received, uint256 minimum);

/**
 * @title AWKZeroXAdapter
 * @notice Generic adapter for token swaps via 0x with pre/post hooks
 * @dev Subclasses can override hooks to add custom logic (e.g., fee tracking).
 */
contract AWKZeroXAdapter is AWKAdapter {
    using SafeERC20 for IERC20;

    address public immutable ALLOWANCE_TARGET;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    event Swapped(address indexed wallet, address indexed target, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount);

    constructor(address allowanceTarget_) {
        if (allowanceTarget_ == address(0)) revert InvalidAllowanceTarget();
        ALLOWANCE_TARGET = allowanceTarget_;
    }

    /**
     * @notice Override execute to handle swap operations
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.swap.selector) {
            (address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) = abi.decode(data[4:], (address, address, uint256, uint256, bytes, uint256));
            (uint256 buyAmount,) = _swapInternal(target, sellToken, buyToken, sellAmount, minBuyAmount, swapCallData, value);
            return abi.encode(buyAmount);
        }
        revert UnknownOperation();
    }

    // ============ Swap Operations ============

    /**
     * @notice Swap tokens via 0x (public interface, should not be called directly)
     * @param sellToken The token to sell (use NATIVE_TOKEN for ETH)
     * @param buyToken The token to buy
     * @param sellAmount The amount of sellToken to swap
     * @param minBuyAmount Minimum acceptable buyToken amount (slippage protection)
     * @param swapCallData The 0x API swap calldata
     * @param value ETH value (ignored for security, sellAmount used instead)
     * @return buyAmount The amount of buyToken received
     * @dev This is a placeholder - actual execution happens via execute() -> _swapInternal()
     */
    function swap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes calldata swapCallData, uint256 value) external payable returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal swap implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _swapInternal(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) internal virtual returns (uint256 buyAmount, uint256 soldAmount) {
        if (sellAmount == 0 || minBuyAmount == 0) revert AWKErrors.ZeroAmount();

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
        soldAmount = sellBalanceBefore - sellBalanceAfter;
        buyAmount = buyBalanceAfter - buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);

        emit Swapped(address(this), target, sellToken, buyToken, soldAmount, buyAmount);
    }
}
