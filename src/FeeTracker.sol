// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "./Errors.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title YieldSeekerFeeTracker
 * @notice Tracks fees for YieldSeeker wallets
 * @dev Called by wallets to record yield and calculate fees.
 *      All recording functions use msg.sender, so callers can only affect their own accounting.
 */
contract YieldSeekerFeeTracker is AccessControl {
    uint256 public constant MAX_FEE_RATE_BPS = 5000;

    uint256 public feeRateBps;
    address public feeCollector;

    mapping(address wallet => uint256) public agentFeesCharged;
    mapping(address wallet => uint256) public agentFeesPaid;

    // Position tracking
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultCostBasis;
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultShares;
    mapping(address wallet => mapping(address token => uint256)) public agentYieldTokenFeesOwed;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);
    event FeePaid(address indexed wallet, uint256 amount);
    event FeeConfigUpdated(uint256 feeRateBps, address feeCollector);

    constructor(address admin) {
        if (admin == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeeConfig(uint256 _feeRateBps, address _feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRateBps > MAX_FEE_RATE_BPS) revert YieldSeekerErrors.InvalidFeeRate();
        if (_feeCollector == address(0)) revert AWKErrors.ZeroAddress();
        feeRateBps = _feeRateBps;
        feeCollector = _feeCollector;
        emit FeeConfigUpdated(_feeRateBps, _feeCollector);
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
     * @notice Get yield token fees owed for a wallet
     * @param wallet The wallet address
     * @param token The token in which yield was earned
     * @return feesOwed The amount of fees owed denominated in the token
     */
    function getAgentYieldTokenFeesOwed(address wallet, address token) external view returns (uint256 feesOwed) {
        feesOwed = agentYieldTokenFeesOwed[wallet][token];
    }

    // ============ Position Tracking ============

    function _chargeFeesOnProfit(address wallet, uint256 profit) internal {
        uint256 fee = (profit * feeRateBps) / 1e4;
        agentFeesCharged[wallet] += fee;
        emit YieldRecorded(wallet, profit, fee);
    }

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
        uint256 vaultTokenFeesOwed = agentYieldTokenFeesOwed[msg.sender][vault];
        uint256 feeInBaseAsset = 0;
        if (vaultTokenFeesOwed > 0) {
            uint256 feeTokenSwapped = sharesSpent > vaultTokenFeesOwed ? vaultTokenFeesOwed : sharesSpent;
            agentYieldTokenFeesOwed[msg.sender][vault] = vaultTokenFeesOwed - feeTokenSwapped;
            feeInBaseAsset = (assetsReceived * feeTokenSwapped) / sharesSpent;
            agentFeesCharged[msg.sender] += feeInBaseAsset;
        }
        if (sharesSpent > totalShares) {
            if (totalCostBasis > 0 && assetsReceived > totalCostBasis + feeInBaseAsset) {
                uint256 profit = assetsReceived - totalCostBasis - feeInBaseAsset;
                _chargeFeesOnProfit(msg.sender, profit);
            }
            agentVaultCostBasis[msg.sender][vault] = 0;
            agentVaultShares[msg.sender][vault] = 0;
        } else if (totalShares > 0) {
            uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
            if (assetsReceived > proportionalCost) {
                uint256 profit = assetsReceived - proportionalCost;
                _chargeFeesOnProfit(msg.sender, profit);
            }
            agentVaultCostBasis[msg.sender][vault] = totalCostBasis - proportionalCost;
            agentVaultShares[msg.sender][vault] = totalShares - sharesSpent;
        }
        emit YieldRecorded(msg.sender, feeInBaseAsset, feeInBaseAsset);
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
     * @notice Record yield earned in a non-base asset token and calculate fees owed
     * @param token The token in which yield was earned
     * @param amount The amount of yield earned in the token
     * @dev Treats yield earned in any token the same way. Calculates fee immediately
     *      and stores the fee portion to be collected when swapped to base asset.
     */
    function recordAgentYieldTokenEarned(address token, uint256 amount) external {
        uint256 feeInToken = (amount * feeRateBps) / 1e4;
        agentYieldTokenFeesOwed[msg.sender][token] += feeInToken;
    }

    /**
     * @notice Record a token swap to base asset and collect fees on yield tokens
     * @param swappedToken The token being swapped
     * @param swappedAmount The amount of tokens swapped
     * @param baseAssetReceived The amount of base asset received
     * @dev Converts yield earned in non-base asset (tracked as fees owed in that token)
     *      to base asset fees when the token is swapped.
     */
    function recordAgentTokenSwap(address swappedToken, uint256 swappedAmount, uint256 baseAssetReceived) external {
        // Guard against division by zero - can happen with broken/paused tokens
        // Allows swap to proceed without charging fees rather than reverting
        if (swappedAmount == 0) return;

        uint256 feeTokenOwed = agentYieldTokenFeesOwed[msg.sender][swappedToken];
        if (feeTokenOwed > 0) {
            // Determine how much of the fee-owed tokens are being swapped
            uint256 feeTokenSwapped = swappedAmount > feeTokenOwed ? feeTokenOwed : swappedAmount;
            // Deduct from the tracked fee owed in this token
            agentYieldTokenFeesOwed[msg.sender][swappedToken] = feeTokenOwed - feeTokenSwapped;
            // Calculate the fee in base asset terms (proportional to amount swapped)
            uint256 feeInBaseAsset = (baseAssetReceived * feeTokenSwapped) / swappedAmount;
            agentFeesCharged[msg.sender] += feeInBaseAsset;
            emit YieldRecorded(msg.sender, feeInBaseAsset, feeInBaseAsset);
        }
    }
}
