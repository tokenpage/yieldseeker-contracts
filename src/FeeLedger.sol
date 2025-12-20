// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title YieldSeekerFeeLedger
 * @notice Tracks fees for YieldSeeker wallets
 * @dev Called by wallets to record yield and calculate fees.
 *      All recording functions use msg.sender, so callers can only affect their own accounting.
 */
contract YieldSeekerFeeLedger is AccessControl {
    uint256 public feeRateBps;
    address public feeCollector;

    mapping(address wallet => uint256) public agentFeesCharged;
    mapping(address wallet => uint256) public agentFeesPaid;

    // Position tracking
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultCostBasis;
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultShares;
    mapping(address wallet => mapping(address token => uint256)) public agentRewardTokenBalances;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);
    event FeePaid(address indexed wallet, uint256 amount);
    event FeeConfigUpdated(uint256 feeRateBps, address feeCollector);

    error ZeroAddress();
    error InvalidFeeRate();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeeConfig(uint256 _feeRateBps, address _feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // NOTE(krishan711): Max fee rate is 50%
        if (_feeRateBps > 5e3) revert InvalidFeeRate();
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeRateBps = _feeRateBps;
        feeCollector = _feeCollector;
        emit FeeConfigUpdated(_feeRateBps, _feeCollector);
    }

    /**
     * @notice Record yield earned and calculate fees
     * @param yieldAmount The amount of yield earned in base asset terms
     */
    function recordYield(uint256 yieldAmount) external {
        uint256 fee = (yieldAmount * feeRateBps) / 1e4;
        agentFeesCharged[msg.sender] += fee;
        emit YieldRecorded(msg.sender, yieldAmount, fee);
    }

    /**
     * @notice Record a fee payment
     * @param amount The amount of fees paid
     */
    function recordFeePaid(uint256 amount) external {
        agentFeesPaid[msg.sender] += amount;
        emit FeePaid(msg.sender, amount);
    }

    /**
     * @notice Get the amount of fees owed by a wallet
     * @param wallet The wallet address
     * @return The amount of fees owed
     */
    function getFeesOwed(address wallet) external view returns (uint256) {
        uint256 charged = agentFeesCharged[wallet];
        uint256 paid = agentFeesPaid[wallet];
        return charged > paid ? charged - paid : 0;
    }

    /**
     * @notice Get wallet fee statistics
     * @param wallet The wallet address
     * @return agentFeesCharged_ Total fees charged to the wallet
     * @return agentFeesPaid_ Total fees paid by the wallet
     * @return feesOwed Current fees owed
     */
    function getWalletStats(address wallet) external view returns (uint256 agentFeesCharged_, uint256 agentFeesPaid_, uint256 feesOwed) {
        agentFeesCharged_ = agentFeesCharged[wallet];
        agentFeesPaid_ = agentFeesPaid[wallet];
        feesOwed = this.getFeesOwed(wallet);
    }

    // ============ Position Tracking ============

    /**
     * @notice Record a vault share deposit for cost-basis tracking
     * @param vault The vault address
     * @param assetsDeposited The amount of assets deposited
     * @param sharesReceived The amount of shares received
     */
    function recordAgentVaultShareDeposit(address vault, uint256 assetsDeposited, uint256 sharesReceived) external {
        agentVaultCostBasis[msg.sender][vault] += assetsDeposited;
        agentVaultShares[msg.sender][vault] += sharesReceived;
    }

    /**
     * @notice Record a vault share withdrawal and calculate yield
     * @param vault The vault address
     * @param sharesSpent The amount of shares withdrawn
     * @param assetsReceived The amount of assets received
     */
    function recordAgentVaultShareWithdraw(address vault, uint256 sharesSpent, uint256 assetsReceived) external {
        uint256 totalShares = agentVaultShares[msg.sender][vault];
        uint256 totalCostBasis = agentVaultCostBasis[msg.sender][vault];
        if (totalShares == 0) return;
        uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
        if (assetsReceived > proportionalCost) {
            uint256 profit = assetsReceived - proportionalCost;
            uint256 fee = (profit * feeRateBps) / 1e4;
            agentFeesCharged[msg.sender] += fee;
            emit YieldRecorded(msg.sender, profit, fee);
        }
        agentVaultCostBasis[msg.sender][vault] = totalCostBasis - proportionalCost;
        agentVaultShares[msg.sender][vault] = totalShares - sharesSpent;
    }

    /**
     * @notice Record yield earned in base asset
     * @param amount The amount of yield earned in base asset
     */
    function recordAgentYieldEarned(uint256 amount) external {
        uint256 fee = (amount * feeRateBps) / 1e4;
        agentFeesCharged[msg.sender] += fee;
        emit YieldRecorded(msg.sender, amount, fee);
    }

    /**
     * @notice Record a reward token claim and track the reward token balance
     * @param token The reward token address
     * @param amount The amount of reward tokens claimed
     */
    function recordAgentRewardClaim(address token, uint256 amount) external {
        agentRewardTokenBalances[msg.sender][token] += amount;
    }

    /**
     * @notice Record a token swap to base asset (rewards are "swapped first")
     * @param swappedToken The token being swapped
     * @param swappedAmount The amount of tokens swapped
     * @param baseAssetReceived The amount of base asset received
     * @dev Uses "rewards first" accounting: if there's a tracked reward balance for the token,
     *      the swap is attributed to rewards (and counted as yield) up to the tracked amount.
     *      Any excess swap amount is treated as non-reward tokens (e.g., user deposits).
     */
    function recordAgentTokenSwap(address swappedToken, uint256 swappedAmount, uint256 baseAssetReceived) external {
        uint256 rewardBalance = agentRewardTokenBalances[msg.sender][swappedToken];
        if (rewardBalance > 0) {
            uint256 rewardPortionSwapped = swappedAmount > rewardBalance ? rewardBalance : swappedAmount;
            agentRewardTokenBalances[msg.sender][swappedToken] = rewardBalance - rewardPortionSwapped;
            uint256 yieldPortion = (baseAssetReceived * rewardPortionSwapped) / swappedAmount;
            uint256 fee = (yieldPortion * feeRateBps) / 1e4;
            agentFeesCharged[msg.sender] += fee;
            emit YieldRecorded(msg.sender, yieldPortion, fee);
        }
    }

    /**
     * @notice Get vault position for a wallet
     * @param wallet The wallet address
     * @param vault The vault address
     * @return costBasis The cost basis in the vault
     * @return shares The vault shares held
     */
    function getAgentVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        costBasis = agentVaultCostBasis[wallet][vault];
        shares = agentVaultShares[wallet][vault];
    }

    /**
     * @notice Get reward token balance tracked for a wallet
     * @param wallet The wallet address
     * @param token The reward token address
     * @return balance The tracked balance
     */
    function getAgentRewardTokenBalance(address wallet, address token) external view returns (uint256 balance) {
        balance = agentRewardTokenBalances[wallet][token];
    }
}
