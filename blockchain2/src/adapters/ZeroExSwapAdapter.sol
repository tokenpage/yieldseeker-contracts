// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ZeroExSwapAdapter
 * @notice Adapter for 0x Protocol swaps
 * @dev This adapter is called via DELEGATECALL from AgentWallet
 *      When executed via delegatecall:
 *      - address(this) = agentWallet address
 *      - msg.sender = original caller (operator)
 *      - Storage/balance context = agentWallet
 *
 *      Security guarantees:
 *      1. Only approves 0x router to spend sellToken (must be pre-approved)
 *      2. Validates output tokens arrive in wallet (balance check)
 *      3. Enforces minimum output amount (slippage protection)
 *      4. All tokens stay in address(this) = agentWallet
 *      5. Clears approval after swap
 *
 *      Usage: Pass arbitrary 0x API calldata while maintaining security
 */
contract ZeroExSwapAdapter {
    using SafeERC20 for IERC20;

    error SwapFailed();
    error InsufficientOutput();

    /// @notice Parameters for a swap
    struct SwapParams {
        address sellToken; // Token to sell
        address buyToken; // Token to buy
        uint256 sellAmount; // Amount to sell
        uint256 minBuyAmount; // Minimum amount to receive (slippage protection)
        bytes swapCallData; // Raw calldata from 0x API
    }

    /**
     * @notice Execute a swap via 0x Protocol
     * @param zeroExRouter Address of the 0x Exchange Proxy
     * @param params Swap parameters
     * @return boughtAmount Amount of buyToken received
     * @dev Via delegatecall (address(this) = agentWallet):
     *      1. Approve router to spend sellToken
     *      2. Execute swap with arbitrary 0x API calldata
     *      3. Validate buyToken balance increased by at least minBuyAmount
     *      4. Clear approval
     *
     *      Security: Balance check ensures tokens arrived in wallet,
     *      regardless of recipient parameter in swapCallData
     */
    function swap(address zeroExRouter, SwapParams calldata params) external returns (uint256 boughtAmount) {
        // Approve router to pull sellToken
        IERC20(params.sellToken).forceApprove(zeroExRouter, params.sellAmount);

        // Record buyToken balance before swap
        uint256 buyTokenBalanceBefore = IERC20(params.buyToken).balanceOf(address(this));

        // Execute swap with arbitrary 0x API calldata
        (bool success,) = zeroExRouter.call(params.swapCallData);
        if (!success) revert SwapFailed();

        // Verify buyToken balance increased
        uint256 buyTokenBalanceAfter = IERC20(params.buyToken).balanceOf(address(this));
        boughtAmount = buyTokenBalanceAfter - buyTokenBalanceBefore;

        // Enforce slippage protection
        if (boughtAmount < params.minBuyAmount) revert InsufficientOutput();

        // Clear approval for security
        IERC20(params.sellToken).forceApprove(zeroExRouter, 0);
    }

    /**
     * @notice Execute multiple swaps in sequence
     * @param zeroExRouter Address of the 0x Exchange Proxy
     * @param swaps Array of swap parameters
     * @return boughtAmounts Array of amounts received for each swap
     * @dev Useful for complex routes or splitting large orders
     */
    function swapMultiple(address zeroExRouter, SwapParams[] calldata swaps) external returns (uint256[] memory boughtAmounts) {
        boughtAmounts = new uint256[](swaps.length);

        for (uint256 i = 0; i < swaps.length; i++) {
            SwapParams calldata params = swaps[i];

            IERC20(params.sellToken).forceApprove(zeroExRouter, params.sellAmount);

            uint256 buyTokenBalanceBefore = IERC20(params.buyToken).balanceOf(address(this));

            (bool success,) = zeroExRouter.call(params.swapCallData);
            if (!success) revert SwapFailed();

            uint256 buyTokenBalanceAfter = IERC20(params.buyToken).balanceOf(address(this));
            boughtAmounts[i] = buyTokenBalanceAfter - buyTokenBalanceBefore;

            if (boughtAmounts[i] < params.minBuyAmount) revert InsufficientOutput();

            IERC20(params.sellToken).forceApprove(zeroExRouter, 0);
        }
    }
}
