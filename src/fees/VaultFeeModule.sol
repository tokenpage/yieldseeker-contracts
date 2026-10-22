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

import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {InvalidFeeRate, YieldSeekerFeePlans} from "./FeePlans.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

bytes32 constant VAULT_FEE = keccak256("vault");

/**
 * @title YieldSeekerVaultFeeModule
 * @notice Fee module for vault yield: a share of realised profit and rewards, owed and paid in the base asset
 * @dev The accounting of the audited YieldSeekerFeeTracker, moved into a module. The fee tracker creates it, forwards
 *      the original tracker interface to it with the calling wallet, and is its only writer.
 *      The rate comes from the owner's plan in the tracker (VAULT_FEE).
 */
contract YieldSeekerVaultFeeModule is IYieldSeekerFeeModule {
    using SafeCast for uint256;

    uint256 public constant ASSET_EXCHANGE_RATE_PRECISION = 1e18;

    YieldSeekerFeePlans public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    struct VaultPosition {
        uint128 costBasis;
        uint128 shares;
    }

    mapping(address wallet => uint256) public agentFeesCharged;
    mapping(address wallet => uint256) public agentFeesPaid;

    // Position tracking (packed into single slot per wallet+vault)
    mapping(address wallet => mapping(address vault => VaultPosition)) internal _agentVaultPositions;
    mapping(address wallet => mapping(address token => uint256)) public agentYieldTokenFeesOwed;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);
    event FeePaid(address indexed wallet, uint256 amount);

    modifier onlyFeeTracker() {
        if (msg.sender != address(FEE_TRACKER)) revert AWKErrors.Unauthorized(msg.sender);
        _;
    }

    constructor(YieldSeekerFeePlans feeTracker, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    function _feeRateBps(address wallet) internal view returns (uint256) {
        return FEE_TRACKER.feeRateBps(VAULT_FEE, wallet);
    }

    /// @notice The base asset may leave minus fees owed; reward fees still owed in another token are held back in it
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        reserved = allowed ? getFeesOwed(wallet) : agentYieldTokenFeesOwed[wallet][token];
    }

    /**
     * @notice Record a fee payment
     * @param wallet The wallet that paid
     * @param amount The amount of fees paid
     */
    function recordFeePaid(address wallet, uint256 amount) external onlyFeeTracker {
        agentFeesPaid[wallet] += amount;
        emit FeePaid(wallet, amount);
    }

    /**
     * @notice Get the amount of fees owed by a wallet
     * @param wallet The wallet address
     * @return The amount of fees owed
     */
    function getFeesOwed(address wallet) public view returns (uint256) {
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
        feesOwed = getFeesOwed(wallet);
    }

    /**
     * @notice Get vault position for a wallet
     * @param wallet The wallet address
     * @param vault The vault address
     * @return costBasis The cost basis in the vault
     * @return shares The vault shares held
     */
    function getAgentVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        costBasis = pos.costBasis;
        shares = pos.shares;
    }

    function agentVaultCostBasis(address wallet, address vault) external view returns (uint256) {
        return _agentVaultPositions[wallet][vault].costBasis;
    }

    function agentVaultShares(address wallet, address vault) external view returns (uint256) {
        return _agentVaultPositions[wallet][vault].shares;
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
     * @param wallet The wallet that deposited
     * @param vault The vault address
     * @param assetsDeposited The amount of assets deposited
     * @param sharesReceived The amount of shares received
     */
    function recordAgentVaultShareDeposit(address wallet, address vault, uint256 assetsDeposited, uint256 sharesReceived) external onlyFeeTracker {
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        pos.costBasis = (uint256(pos.costBasis) + assetsDeposited).toUint128();
        pos.shares = (uint256(pos.shares) + sharesReceived).toUint128();
    }

    function _chargeFeesOnProfit(address wallet, uint256 profit) internal {
        uint256 fee = (profit * _feeRateBps(wallet)) / 1e4;
        agentFeesCharged[wallet] += fee;
        emit YieldRecorded(wallet, profit, fee);
    }

    /**
     * @notice Record a vault share withdrawal and calculate yield
     * @param wallet The wallet that withdrew
     * @param vault The vault address
     * @param sharesSpent The amount of shares withdrawn
     * @param assetsReceived The amount of assets received
     */
    function recordAgentVaultShareWithdraw(address wallet, address vault, uint256 sharesSpent, uint256 assetsReceived) external onlyFeeTracker {
        if (sharesSpent == 0) return;
        uint256 feeRateBps = _feeRateBps(wallet);
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        uint256 totalShares = pos.shares;
        uint256 totalCostBasis = pos.costBasis;
        uint256 vaultTokenFeesOwed = agentYieldTokenFeesOwed[wallet][vault];
        uint256 feeInBaseAsset = 0;
        uint256 rewardValueInBaseAsset = 0;
        if (vaultTokenFeesOwed > 0) {
            // Convert fee-owed vault tokens into base asset fees
            uint256 feeTokenSwapped = sharesSpent > vaultTokenFeesOwed ? vaultTokenFeesOwed : sharesSpent;
            agentYieldTokenFeesOwed[wallet][vault] = vaultTokenFeesOwed - feeTokenSwapped;
            feeInBaseAsset = (assetsReceived * feeTokenSwapped) / sharesSpent;
            agentFeesCharged[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
            // The reward tokens already had their fee assessed above. Exclude their full
            // (pre-fee) base-asset value from the appreciation comparison below, otherwise
            // the post-fee remainder is taxed a second time as vault-appreciation profit.
            if (feeRateBps > 0) {
                rewardValueInBaseAsset = (feeInBaseAsset * 1e4) / feeRateBps;
                if (rewardValueInBaseAsset > assetsReceived) {
                    rewardValueInBaseAsset = assetsReceived;
                }
            }
        }
        uint256 excludedRewardValue = rewardValueInBaseAsset > feeInBaseAsset ? rewardValueInBaseAsset : feeInBaseAsset;
        uint256 netAssets = assetsReceived - excludedRewardValue;
        if (sharesSpent > totalShares) {
            // Withdrawing more shares than deposits tracked - treat as full withdrawal
            if (totalCostBasis > 0 && totalShares > 0) {
                uint256 depositSharesValue = (netAssets * totalShares) / sharesSpent;
                if (depositSharesValue > totalCostBasis) {
                    uint256 profit = depositSharesValue - totalCostBasis;
                    _chargeFeesOnProfit(wallet, profit);
                }
            }
            pos.costBasis = 0;
            pos.shares = 0;
        } else if (totalShares > 0) {
            // Normal withdrawal within tracked deposits
            uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
            if (netAssets > proportionalCost) {
                uint256 profit = netAssets - proportionalCost;
                _chargeFeesOnProfit(wallet, profit);
            }
            pos.costBasis = (totalCostBasis - proportionalCost).toUint128();
            pos.shares = (totalShares - sharesSpent).toUint128();
        }
    }

    /**
     * @notice Record a vault asset withdrawal and calculate yield using actual vault balance
     * @param wallet The wallet that withdrew
     * @param vault The vault address
     * @param assetsReceived The amount of base assets received from the withdrawal
     * @param totalVaultBalanceBefore The total vault balance (in base asset terms) before withdrawal
     * @param vaultTokenToBaseAssetRate The exchange rate from vault tokens to base asset (18-decimal fixed point).
     *        For rebasing tokens (Aave, CompoundV3), this should be 1e18 (1:1 with underlying).
     *        For exchange-rate tokens (CompoundV2), this should be the cToken exchange rate.
     */
    function recordAgentVaultAssetWithdraw(address wallet, address vault, uint256 assetsReceived, uint256 totalVaultBalanceBefore, uint256 vaultTokenToBaseAssetRate) external onlyFeeTracker {
        if (assetsReceived == 0 || totalVaultBalanceBefore == 0) return;
        uint256 feeRateBps = _feeRateBps(wallet);
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        uint256 totalCostBasis = pos.costBasis;
        uint256 totalShares = pos.shares;
        uint256 vaultTokenFeesOwed = agentYieldTokenFeesOwed[wallet][vault];
        uint256 feeInBaseAsset = 0;
        uint256 rewardValueInBaseAsset = 0;
        if (vaultTokenFeesOwed > 0) {
            uint256 feeTokenSettled;
            if (assetsReceived >= totalVaultBalanceBefore) {
                feeTokenSettled = vaultTokenFeesOwed;
            } else {
                feeTokenSettled = (vaultTokenFeesOwed * assetsReceived) / totalVaultBalanceBefore;
            }
            agentYieldTokenFeesOwed[wallet][vault] = vaultTokenFeesOwed - feeTokenSettled;
            feeInBaseAsset = (feeTokenSettled * vaultTokenToBaseAssetRate) / ASSET_EXCHANGE_RATE_PRECISION;
            if (feeInBaseAsset > assetsReceived) {
                feeInBaseAsset = assetsReceived;
            }
            agentFeesCharged[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
            // The reward tokens already had their fee assessed above. Exclude their full
            // (pre-fee) base-asset value from the appreciation comparison below, otherwise
            // the post-fee remainder is taxed a second time as vault-appreciation profit.
            if (feeRateBps > 0) {
                rewardValueInBaseAsset = (feeInBaseAsset * 1e4) / feeRateBps;
                if (rewardValueInBaseAsset > assetsReceived) {
                    rewardValueInBaseAsset = assetsReceived;
                }
            }
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
        uint256 excludedRewardValue = rewardValueInBaseAsset > feeInBaseAsset ? rewardValueInBaseAsset : feeInBaseAsset;
        uint256 netAssets = assetsReceived - excludedRewardValue;
        if (netAssets > proportionalCost) {
            uint256 profit = netAssets - proportionalCost;
            _chargeFeesOnProfit(wallet, profit);
        }
        pos.costBasis = (totalCostBasis - proportionalCost).toUint128();
        pos.shares = (totalShares - proportionalShares).toUint128();
    }

    /**
     * @notice Record yield earned in base asset
     * @param wallet The wallet that earned
     * @param amount The amount of yield earned in base asset
     */
    function recordAgentYieldEarned(address wallet, uint256 amount) external onlyFeeTracker {
        uint256 fee = (amount * _feeRateBps(wallet)) / 1e4;
        agentFeesCharged[wallet] += fee;
        emit YieldRecorded(wallet, amount, fee);
    }

    /**
     * @notice Record yield earned in a non-base asset token and calculate fees owed
     * @param wallet The wallet that earned
     * @param token The token in which yield was earned
     * @param amount The amount of yield earned in the token
     * @dev Treats yield earned in any token the same way. Calculates fee immediately
     *      and stores the fee portion to be collected when swapped to base asset.
     */
    function recordAgentYieldTokenEarned(address wallet, address token, uint256 amount) external onlyFeeTracker {
        uint256 feeInToken = (amount * _feeRateBps(wallet)) / 1e4;
        agentYieldTokenFeesOwed[wallet][token] += feeInToken;
    }

    /**
     * @notice Record a token swap to base asset and collect fees on yield tokens
     * @param wallet The wallet that swapped
     * @param swappedToken The token being swapped
     * @param swappedAmount The amount of tokens swapped
     * @param baseAssetReceived The amount of base asset received
     * @dev Converts yield earned in non-base asset (tracked as fees owed in that token)
     *      to base asset fees when the token is swapped.
     */
    function recordAgentTokenSwap(address wallet, address swappedToken, uint256 swappedAmount, uint256 baseAssetReceived) external onlyFeeTracker {
        // Guard against division by zero - can happen with broken/paused tokens
        // Allows swap to proceed without charging fees rather than reverting
        if (swappedAmount == 0) return;

        uint256 feeTokenOwed = agentYieldTokenFeesOwed[wallet][swappedToken];
        if (feeTokenOwed > 0) {
            // Determine how much of the fee-owed tokens are being swapped
            uint256 feeTokenSwapped = swappedAmount > feeTokenOwed ? feeTokenOwed : swappedAmount;
            // Deduct from the tracked fee owed in this token
            agentYieldTokenFeesOwed[wallet][swappedToken] = feeTokenOwed - feeTokenSwapped;
            // Calculate the fee in base asset terms (proportional to amount swapped)
            uint256 feeInBaseAsset = (baseAssetReceived * feeTokenSwapped) / swappedAmount;
            agentFeesCharged[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
        }
    }
}
