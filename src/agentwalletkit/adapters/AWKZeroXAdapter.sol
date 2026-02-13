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
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

error InvalidAllowanceTarget();
error InsufficientEth(uint256 balance, uint256 required);
error SwapFailed(bytes reason);
error InsufficientOutput(uint256 received, uint256 minimum);
error SellTokenNotAllowed(address token);

/**
 * @title AWKZeroXAdapter
 * @notice Generic adapter for token swaps via 0x with built-in sell-token allowlist.
 * @dev Swap execution runs via delegatecall from AgentWallet.
 *      Allowlist management functions run via direct calls (admin-only).
 *      When allowSellingAllTokens is false, only tokens explicitly added to the allowlist can be sold.
 *      When allowSellingAllTokens is true, any token can be sold (useful for less restrictive setups).
 */
contract AWKZeroXAdapter is AWKAdapter, AccessControl {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    address public immutable ALLOWANCE_TARGET;
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bool public allowSellingAllTokens;
    EnumerableSet.AddressSet private sellableTokens;

    event SellableTokenAdded(address indexed token);
    event SellableTokenRemoved(address indexed token);
    event AllowSellingAllTokensSet(bool enabled);
    event Swapped(address indexed wallet, address indexed target, address sellToken, address buyToken, uint256 sellAmount, uint256 buyAmount);

    /// @param allowanceTarget The 0x exchange proxy allowance target for token approvals
    /// @param admin Address of the admin (gets DEFAULT_ADMIN_ROLE for allowlist and configuration)
    /// @param emergencyAdmin Address that can perform emergency operations (remove sellable tokens)
    /// @param initialAllowSellingAllTokens Whether to allow selling all tokens by default
    constructor(address allowanceTarget, address admin, address emergencyAdmin, bool initialAllowSellingAllTokens) {
        if (allowanceTarget == address(0)) revert InvalidAllowanceTarget();
        if (admin == address(0)) revert AWKErrors.ZeroAddress();
        if (emergencyAdmin == address(0)) revert AWKErrors.ZeroAddress();
        ALLOWANCE_TARGET = allowanceTarget;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergencyAdmin);
        allowSellingAllTokens = initialAllowSellingAllTokens;
    }

    // ============ Allowlist Management (direct calls only) ============

    /// @notice Toggle the global flag that allows selling any token, bypassing the allowlist
    /// @param enabled True to allow selling all tokens, false to enforce the allowlist
    function setAllowSellingAllTokens(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowSellingAllTokens = enabled;
        emit AllowSellingAllTokensSet(enabled);
    }

    /// @notice Add a token to the sell allowlist
    /// @param token The token address to allow selling
    function addSellableToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert AWKErrors.ZeroAddress();
        if (sellableTokens.add(token)) {
            emit SellableTokenAdded(token);
        }
    }

    /// @notice Add multiple tokens to the sell allowlist in a single transaction
    /// @param tokens The token addresses to allow selling
    function addSellableTokens(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert AWKErrors.ZeroAddress();
            if (sellableTokens.add(tokens[i])) {
                emit SellableTokenAdded(tokens[i]);
            }
        }
    }

    /// @notice Remove a token from the sell allowlist (emergency only)
    /// @param token The token address to disallow selling
    function removeSellableToken(address token) external onlyRole(EMERGENCY_ROLE) {
        if (sellableTokens.remove(token)) {
            emit SellableTokenRemoved(token);
        }
    }

    /// @notice Check if a token is allowed to be sold
    /// @param token The token address to check
    /// @return True if the token can be sold (either explicitly allowlisted or allowSellingAllTokens is enabled)
    function isSellableToken(address token) external view returns (bool) {
        return allowSellingAllTokens || sellableTokens.contains(token);
    }

    /// @notice Get all tokens explicitly added to the sell allowlist
    /// @return An array of token addresses in the allowlist
    function getSellableTokens() external view returns (address[] memory) {
        return sellableTokens.values();
    }

    // ============ Swap Execution (delegatecall only) ============

    /**
     * @notice Route delegatecall operations to the appropriate swap handler
     * @param target The 0x swap target contract
     * @param data ABI-encoded call data (must match swap() selector)
     * @return ABI-encoded buy amount
     * @dev Only callable via delegatecall from AgentWallet. Reverts with UnknownOperation for unrecognised selectors.
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector_ = bytes4(data[:4]);
        if (selector_ == this.swap.selector) {
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
     * @notice Internal swap implementation that handles token approvals, balance checks, and slippage protection
     * @param target The 0x swap target contract to call
     * @param sellToken The token being sold (use NATIVE_TOKEN for ETH)
     * @param buyToken The token being bought
     * @param sellAmount The amount of sellToken to sell
     * @param minBuyAmount Minimum acceptable buyToken output (reverts with InsufficientOutput if not met)
     * @param swapCallData Raw calldata to forward to the 0x target
     * @param value Ignored - sellAmount is used for ETH sends to prevent value manipulation
     * @return buyAmount The amount of buyToken received
     * @return soldAmount The amount of sellToken actually sold
     * @dev Runs in the wallet's context via delegatecall. Reads the adapter's own allowlist
     *      via an external call to AWKZeroXAdapter(SELF).isSellableToken() since storage
     *      belongs to the wallet during delegatecall.
     */
    function _swapInternal(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) internal virtual returns (uint256 buyAmount, uint256 soldAmount) {
        if (sellAmount == 0 || minBuyAmount == 0) revert AWKErrors.ZeroAmount();
        if (sellToken != NATIVE_TOKEN && !AWKZeroXAdapter(SELF).isSellableToken(sellToken)) revert SellTokenNotAllowed(sellToken);

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
