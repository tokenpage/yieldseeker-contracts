// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultProvider} from "./vaults/IVaultProvider.sol";
import {YieldSeekerAccessController} from "./AccessController.sol";

/**
 * @title YieldSeekerAgentWallet
 * @notice Implementation contract for agent wallet logic
 * @dev All agent wallets are minimal proxies that delegate to this contract
 *      Enforces security constraints:
 *      - Only YieldSeekerAccessController can call vault/swap operations
 *      - Only approved vaults can be used (VaultRegistry)
 *      - Only approved swap providers can be used (SwapRegistry)
 *      - User withdrawals go ONLY to user address
 *      - No arbitrary external calls
 */
contract YieldSeekerAgentWallet {
    using SafeERC20 for IERC20;

    /// @notice YieldSeekerAccessController contract
    YieldSeekerAccessController public immutable operator;

    /// @notice User who owns this agent wallet (set during initialization)
    address public owner;

    /// @notice Agent index for this owner (set during initialization)
    uint256 public ownerAgentIndex;

    /// @notice Base asset token this agent operates with (e.g., USDC) - set during initialization
    IERC20 public baseAsset;

    /// @notice Struct for a withdrawal operation with percentage
    struct WithdrawOperation {
        address vault;
        uint256 percentageBps; // Percentage in basis points (10_000 = 100%)
    }

    /// @notice Struct for a deposit operation with percentage
    struct DepositOperation {
        address vault;
        uint256 percentageBps; // Percentage in basis points (10_000 = 100%)
    }

    event Initialized(address indexed owner, uint256 indexed ownerAgentIndex);
    event DepositedToVault(address indexed vault, uint256 amount, uint256 shares);
    event WithdrewFromVault(address indexed vault, uint256 shares, uint256 amount);
    event Swapped(address indexed provider, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event ClaimedRewards(address indexed vault, address[] tokens, uint256[] amounts);
    event WithdrewBaseAssetToUser(address indexed owner, address indexed recipient, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event Rebalanced(address indexed operator, uint256 withdrawals, uint256 deposits);

    error NotOperator();
    error NotOwner();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidAddress();
    error SwapProviderNotApproved();
    error InsufficientBalance();
    error InsufficientShares();
    error InsufficientWithdrawableShares();
    error SlippageExceeded();
    error TransferFailed();
    error SystemPaused();
    error InvalidPercentage();

    modifier onlyOperator() {
        if (!operator.isAuthorizedOperator(msg.sender)) revert NotOperator();
        if (owner == address(0)) revert NotInitialized();
        if (operator.paused()) revert SystemPaused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _operator) {
        if (_operator == address(0)) revert InvalidAddress();
        operator = YieldSeekerAccessController(_operator);
    }

    /**
     * @notice Initialize the agent wallet
     * @param _owner User who owns this agent wallet
     * @param _ownerAgentIndex Agent index for this owner
     * @param _baseAsset Base asset token address (e.g., USDC)
     * @dev Called once during proxy deployment
     */
    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        if (_baseAsset == address(0)) revert InvalidAddress();
        owner = _owner;
        ownerAgentIndex = _ownerAgentIndex;
        baseAsset = IERC20(_baseAsset);
        emit Initialized(_owner, _ownerAgentIndex);
    }

    // ============ VAULT OPERATIONS ============

    /**
     * @notice Deposit base asset to a vault
     * @param vault Vault address
     * @param amount Amount to deposit
     */
    function depositToVault(address vault, uint256 amount) external onlyOperator {
        address provider = operator.getVaultProvider(vault);
        uint256 balance = baseAsset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        baseAsset.forceApprove(provider, amount);
        uint256 shares = IVaultProvider(provider).deposit(vault, address(baseAsset), amount);
        emit DepositedToVault(vault, amount, shares);
    }

    /**
     * @notice Withdraw tokens from a vault
     * @param vault Vault address
     * @param shares Amount of shares to withdraw
     */
    function withdrawFromVault(address vault, uint256 shares) external onlyOperator {
        address provider = operator.getVaultProvider(vault);
        uint256 withdrawableShares = IVaultProvider(provider).getWithdrawableShareCount(vault, address(this));
        if (withdrawableShares < shares) revert InsufficientWithdrawableShares();
        _withdrawFromVault(vault, provider, shares);
    }

    /**
     * @notice Internal function to withdraw from vault and emit event
     * @param vault Vault address
     * @param provider Vault provider address
     * @param shares Amount of shares to withdraw
     */
    function _withdrawFromVault(address vault, address provider, uint256 shares) internal {
        uint256 amount = IVaultProvider(provider).withdraw(vault, shares);
        emit WithdrewFromVault(vault, shares, amount);
    }

    // ============ FUTURE FUNCTIONALITY (COMMENTED OUT FOR NOW) ============
    // TODO: Implement these once deposit/withdraw are fully tested

    // /**
    //  * @notice Claim rewards from a vault
    //  * @param vault Vault provider address
    //  */
    // function claimRewards(address vault) external onlyOperator {
    //     if (!operator.isVaultApproved(vault)) revert VaultNotApproved();
    //     (address[] memory tokens, uint256[] memory amounts) = IVaultProvider(vault).claimRewards();
    //     emit ClaimedRewards(vault, tokens, amounts);
    // }

    // // ============ SWAP OPERATIONS ============

    // /**
    //  * @notice Swap tokens via approved DEX
    //  * @param swapProvider Swap provider address
    //  * @param tokenIn Token to swap from
    //  * @param tokenOut Token to swap to
    //  * @param amountIn Amount of tokenIn to swap
    //  * @param minAmountOut Minimum amount of tokenOut to receive (slippage protection)
    //  */
    // function swapTokens(address swapProvider, address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external onlyOperator {
    //     if (!operator.isSwapApproved(swapProvider)) revert SwapProviderNotApproved();
    //     IERC20 tokenInContract = IERC20(tokenIn);
    //     uint256 balance = tokenInContract.balanceOf(address(this));
    //     if (balance < amountIn) revert InsufficientBalance();
    //     tokenInContract.approve(swapProvider, amountIn);
    //     uint256 amountOut = ISwapProvider(swapProvider).swap(tokenIn, tokenOut, amountIn, minAmountOut, address(this));
    //     if (amountOut < minAmountOut) revert SlippageExceeded();
    //     emit Swapped(swapProvider, tokenIn, tokenOut, amountIn, amountOut);
    // }

    // ============ REBALANCING OPERATIONS ============

    /**
     * @notice Rebalance portfolio across vaults using percentage-based withdrawals and deposits
     * @param withdrawals Array of withdrawal operations (vault, percentageBps of shares to withdraw)
     * @param deposits Array of deposit operations (vault, percentageBps of baseAsset to deposit)
     * @dev Withdrawals are executed first (freeing up baseAsset), then deposits
     *      Percentages are in basis points (10_000 = 100%, 5000 = 50%, etc.)
     *      This allows the backend to specify target allocations as percentages
     */
    function rebalance(WithdrawOperation[] calldata withdrawals, DepositOperation[] calldata deposits) external onlyOperator {
        // Execute all withdrawals first (converting shares to baseAsset)
        for (uint256 i = 0; i < withdrawals.length; i++) {
            address vault = withdrawals[i].vault;
            uint256 percentageBps = withdrawals[i].percentageBps;
            if (percentageBps > 10_000) revert InvalidPercentage();
            if (percentageBps == 0) continue;
            address provider = operator.getVaultProvider(vault);
            uint256 totalShares = IVaultProvider(provider).getShareCount(vault, address(this));
            uint256 sharesToWithdraw = (totalShares * percentageBps) / 10_000;
            uint256 withdrawableShares = IVaultProvider(provider).getWithdrawableShareCount(vault, address(this));
            if (withdrawableShares < sharesToWithdraw) {
                // TODO(krishan711): we should really request more withdrawal here
            }
            uint256 actualSharesToWithdraw = sharesToWithdraw > withdrawableShares ? withdrawableShares : sharesToWithdraw;
            if (actualSharesToWithdraw == 0) continue;
            _withdrawFromVault(vault, provider, actualSharesToWithdraw);
        }
        // Execute all deposits (converting baseAsset to shares)
        uint256 baseAssetBalance = baseAsset.balanceOf(address(this));
        for (uint256 i = 0; i < deposits.length; i++) {
            address vault = deposits[i].vault;
            uint256 percentageBps = deposits[i].percentageBps;
            if (percentageBps > 10_000) revert InvalidPercentage();
            if (percentageBps == 0) continue;
            uint256 amountToDeposit = (baseAssetBalance * percentageBps) / 10_000;
            if (amountToDeposit == 0) continue;
            address provider = operator.getVaultProvider(vault);
            baseAsset.forceApprove(provider, amountToDeposit);
            uint256 newShares = IVaultProvider(provider).deposit(vault, address(baseAsset), amountToDeposit);
            emit DepositedToVault(vault, amountToDeposit, newShares);
        }
        emit Rebalanced(msg.sender, withdrawals.length, deposits.length);
    }

    // ============ USER OPERATIONS ============

    /**
     * @notice User withdraws base asset from agent wallet
     * @param recipient Address to send the base asset to
     * @param amount Amount to withdraw
     * @dev Only callable by owner, but can send to any address (for wallet recovery)
     */
    function withdrawBaseAssetToUser(address recipient, uint256 amount) external onlyOwner {
        uint256 balance = baseAsset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        _withdrawBaseAsset(recipient, amount);
    }

    /**
     * @notice User withdraws all base asset from agent wallet
     * @param recipient Address to send the base asset to
     * @dev Only callable by owner, withdraws entire balance
     */
    function withdrawAllBaseAssetToUser(address recipient) external onlyOwner {
        uint256 balance = baseAsset.balanceOf(address(this));
        _withdrawBaseAsset(recipient, balance);
    }

    /**
     * @notice User withdraws ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     * @dev Only callable by owner, allows withdrawal of gas refunds, airdrops, etc.
     */
    function withdrawEthToUser(address recipient, uint256 amount) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance < amount) revert InsufficientBalance();
        _withdrawEth(recipient, amount);
    }

    /**
     * @notice User withdraws all ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @dev Only callable by owner, withdraws entire ETH balance
     */
    function withdrawAllEthToUser(address recipient) external onlyOwner {
        uint256 balance = address(this).balance;
        _withdrawEth(recipient, balance);
    }

    /**
     * @notice Internal function to withdraw base asset
     * @param recipient Address to send the base asset to
     * @param amount Amount to withdraw (balance already validated)
     */
    function _withdrawBaseAsset(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        baseAsset.safeTransfer(recipient, amount);
        emit WithdrewBaseAssetToUser(owner, recipient, amount);
    }

    /**
     * @notice Internal function to withdraw ETH
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw (balance already validated)
     */
    function _withdrawEth(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit WithdrewEthToUser(owner, recipient, amount);
    }

    /**
     * @notice User withdraws from all vaults in emergency situations
     * @param vaults Array of vault addresses to withdraw from
     * @dev Withdraws maximum withdrawable shares from specified vaults (respects liquidity limits)
     *      User can then call withdrawBaseAssetToUser to get the funds
     *      May need to be called multiple times if vault has withdrawal limits
     */
    function withdrawFromAllVaults(address[] calldata vaults) external onlyOwner {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            address provider = operator.getVaultProvider(vault);
            uint256 withdrawableShares = IVaultProvider(provider).getWithdrawableShareCount(vault, address(this));
            if (withdrawableShares > 0) {
                _withdrawFromVault(vault, provider, withdrawableShares);
            }
        }
    }

    /**
     * @notice Receive ETH (for gas refunds, etc.)
     */
    receive() external payable {}
}
