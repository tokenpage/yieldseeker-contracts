// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error InvalidFeeRate();

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
        if (_feeRateBps > MAX_FEE_RATE_BPS) revert InvalidFeeRate();
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

    function _chargeFeesOnProfit(address wallet, uint256 profit) internal {
        uint256 fee = (profit * feeRateBps) / 1e4;
        agentFeesCharged[wallet] += fee;
        emit YieldRecorded(wallet, profit, fee);
    }

    /**
     * @notice Record a vault share withdrawal and calculate yield
     * @param vault The vault address
     * @param sharesSpent The amount of shares withdrawn
     * @param assetsReceived The amount of assets received
     */
    function recordAgentVaultShareWithdraw(address vault, uint256 sharesSpent, uint256 assetsReceived) external {
        if (sharesSpent == 0) return;
        address wallet = msg.sender;
        uint256 totalShares = agentVaultShares[wallet][vault];
        uint256 totalCostBasis = agentVaultCostBasis[wallet][vault];
        uint256 vaultTokenFeesOwed = agentYieldTokenFeesOwed[wallet][vault];
        uint256 feeInBaseAsset = 0;
        if (vaultTokenFeesOwed > 0) {
            // Convert fee-owed vault tokens into base asset fees
            uint256 feeTokenSwapped = sharesSpent > vaultTokenFeesOwed ? vaultTokenFeesOwed : sharesSpent;
            agentYieldTokenFeesOwed[wallet][vault] = vaultTokenFeesOwed - feeTokenSwapped;
            feeInBaseAsset = (assetsReceived * feeTokenSwapped) / sharesSpent;
            agentFeesCharged[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
        }
        if (sharesSpent > totalShares) {
            // Withdrawing more shares than deposits tracked - treat as full withdrawal
            if (totalCostBasis > 0 && totalShares > 0) {
                uint256 depositSharesValue = (assetsReceived * totalShares) / sharesSpent;
                if (depositSharesValue > totalCostBasis) {
                    uint256 profit = depositSharesValue - totalCostBasis;
                    _chargeFeesOnProfit(wallet, profit);
                }
            }
            agentVaultCostBasis[wallet][vault] = 0;
            agentVaultShares[wallet][vault] = 0;
            return;
        } else if (totalShares > 0) {
            // Normal withdrawal within tracked deposits
            uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
            uint256 netAssets = assetsReceived - feeInBaseAsset;
            if (netAssets > proportionalCost) {
                uint256 profit = netAssets - proportionalCost;
                _chargeFeesOnProfit(wallet, profit);
            }
            agentVaultCostBasis[wallet][vault] = totalCostBasis - proportionalCost;
            agentVaultShares[wallet][vault] = totalShares - sharesSpent;
        }
    }

    /**
     * @notice Record a vault asset withdrawal and calculate yield using actual vault balance
     * @param vault The vault address
     * @param assetsReceived The amount of base assets received from the withdrawal
     * @param totalVaultBalanceBefore The total vault balance (in base asset terms) before withdrawal
     * @dev Uses actual vault balance to compute proportional cost basis, avoiding virtual share conversion.
     *      For rebasing tokens (Aave, CompoundV3), totalVaultBalanceBefore is the token balance.
     *      For exchange-rate tokens (CompoundV2), totalVaultBalanceBefore is the underlying value.
     */
    function recordAgentVaultAssetWithdraw(address vault, uint256 assetsReceived, uint256 totalVaultBalanceBefore) external {
        if (assetsReceived == 0 || totalVaultBalanceBefore == 0) return;
        address wallet = msg.sender;
        uint256 totalCostBasis = agentVaultCostBasis[wallet][vault];
        uint256 totalShares = agentVaultShares[wallet][vault];
        uint256 vaultTokenFeesOwed = agentYieldTokenFeesOwed[wallet][vault];
        uint256 feeInBaseAsset = 0;
        if (vaultTokenFeesOwed > 0) {
            uint256 feeTokenSettled;
            if (assetsReceived >= totalVaultBalanceBefore) {
                feeTokenSettled = vaultTokenFeesOwed;
            } else {
                feeTokenSettled = (vaultTokenFeesOwed * assetsReceived) / totalVaultBalanceBefore;
            }
            agentYieldTokenFeesOwed[wallet][vault] = vaultTokenFeesOwed - feeTokenSettled;
            feeInBaseAsset = feeTokenSettled;
            agentFeesCharged[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
        }
        uint256 proportionalCost;
        uint256 proportionalShares;
        if (assetsReceived >= totalVaultBalanceBefore) {
            proportionalCost = totalCostBasis;
            proportionalShares = totalShares;
        } else {
            proportionalCost = (totalCostBasis * assetsReceived) / totalVaultBalanceBefore;
            proportionalShares = (totalShares * assetsReceived) / totalVaultBalanceBefore;
        }
        uint256 netAssets = assetsReceived - feeInBaseAsset;
        if (netAssets > proportionalCost) {
            uint256 profit = netAssets - proportionalCost;
            _chargeFeesOnProfit(wallet, profit);
        }
        agentVaultCostBasis[wallet][vault] = totalCostBasis - proportionalCost;
        agentVaultShares[wallet][vault] = totalShares - proportionalShares;
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
