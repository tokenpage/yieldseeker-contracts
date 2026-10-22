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

import {IAgentWallet} from "./IAgentWallet.sol";
import {YieldSeekerFeePlans} from "./fees/FeePlans.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "./fees/VaultFeeModule.sol";

/**
 * @title YieldSeekerFeeTracker
 * @notice Tracks fees for YieldSeeker wallets through pluggable fee modules
 * @dev Every fee type is a module with its own accounting; the tracker holds the plans, the fee collector and the
 *      module list (YieldSeekerFeePlans). The vault fee module is created here and the original tracker interface
 *      (used by the vault adapters and wallets) is forwarded to it with msg.sender as the wallet, so callers can only
 *      affect their own accounting. Other modules (e.g. the borrow fee) are added by the admin and called by their
 *      adapters directly. withdrawReserve() combines every module's answer.
 */
contract YieldSeekerFeeTracker is YieldSeekerFeePlans {
    uint256 public constant ASSET_EXCHANGE_RATE_PRECISION = 1e18;
    uint256 public constant MODULE_GAS_LIMIT = 200_000;

    YieldSeekerVaultFeeModule public immutable VAULT_FEE_MODULE;

    constructor(address admin, address planManager, address initialFeeCollector, uint256 maxVaultFeeRateBps, uint256 defaultVaultFeeRateBps) YieldSeekerFeePlans(admin, planManager, initialFeeCollector) {
        VAULT_FEE_MODULE = new YieldSeekerVaultFeeModule(this, maxVaultFeeRateBps);
        _addFeeModule(VAULT_FEE, VAULT_FEE_MODULE);
        _setPlanRate(0, VAULT_FEE, defaultVaultFeeRateBps);
    }

    /**
     * @notice Whether `token` may leave `wallet`, and how much of it the wallet must keep for fees owed
     * @dev The base asset may always leave; other tokens only if a module accounts for them. Each module is called
     *      with a gas limit and a module that fails counts as (false, 0), so no module can block a wallet's exits.
     */
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        for (uint256 i = 0; i < _moduleFeeTypes.length; i++) {
            try feeModules[_moduleFeeTypes[i]].withdrawReserve{gas: MODULE_GAS_LIMIT}(wallet, token) returns (bool moduleAllows, uint256 moduleReserved) {
                allowed = allowed || moduleAllows;
                reserved += moduleReserved;
            } catch {}
        }
    }

    // ============ Vault fee module (original YieldSeekerFeeTracker interface) ============

    function recordFeePaid(uint256 amount) external {
        VAULT_FEE_MODULE.recordFeePaid(msg.sender, amount);
    }

    function getFeesOwed(address wallet) external view returns (uint256) {
        return VAULT_FEE_MODULE.getFeesOwed(wallet);
    }

    function getWalletStats(address wallet) external view returns (uint256 agentFeesCharged_, uint256 agentFeesPaid_, uint256 feesOwed) {
        return VAULT_FEE_MODULE.getWalletStats(wallet);
    }

    function getAgentVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        return VAULT_FEE_MODULE.getAgentVaultPosition(wallet, vault);
    }

    function agentFeesCharged(address wallet) external view returns (uint256) {
        return VAULT_FEE_MODULE.agentFeesCharged(wallet);
    }

    function agentFeesPaid(address wallet) external view returns (uint256) {
        return VAULT_FEE_MODULE.agentFeesPaid(wallet);
    }

    function agentVaultCostBasis(address wallet, address vault) external view returns (uint256) {
        return VAULT_FEE_MODULE.agentVaultCostBasis(wallet, vault);
    }

    function agentVaultShares(address wallet, address vault) external view returns (uint256) {
        return VAULT_FEE_MODULE.agentVaultShares(wallet, vault);
    }

    function agentYieldTokenFeesOwed(address wallet, address token) external view returns (uint256) {
        return VAULT_FEE_MODULE.agentYieldTokenFeesOwed(wallet, token);
    }

    function getAgentYieldTokenFeesOwed(address wallet, address token) external view returns (uint256 feesOwed) {
        return VAULT_FEE_MODULE.getAgentYieldTokenFeesOwed(wallet, token);
    }

    function recordAgentVaultShareDeposit(address vault, uint256 assetsDeposited, uint256 sharesReceived) external {
        VAULT_FEE_MODULE.recordAgentVaultShareDeposit(msg.sender, vault, assetsDeposited, sharesReceived);
    }

    function recordAgentVaultShareWithdraw(address vault, uint256 sharesSpent, uint256 assetsReceived) external {
        VAULT_FEE_MODULE.recordAgentVaultShareWithdraw(msg.sender, vault, sharesSpent, assetsReceived);
    }

    function recordAgentVaultAssetWithdraw(address vault, uint256 assetsReceived, uint256 totalVaultBalanceBefore, uint256 vaultTokenToBaseAssetRate) external {
        VAULT_FEE_MODULE.recordAgentVaultAssetWithdraw(msg.sender, vault, assetsReceived, totalVaultBalanceBefore, vaultTokenToBaseAssetRate);
    }

    function recordAgentYieldEarned(uint256 amount) external {
        VAULT_FEE_MODULE.recordAgentYieldEarned(msg.sender, amount);
    }

    function recordAgentYieldTokenEarned(address token, uint256 amount) external {
        VAULT_FEE_MODULE.recordAgentYieldTokenEarned(msg.sender, token, amount);
    }

    function recordAgentTokenSwap(address swappedToken, uint256 swappedAmount, uint256 baseAssetReceived) external {
        VAULT_FEE_MODULE.recordAgentTokenSwap(msg.sender, swappedToken, swappedAmount, baseAssetReceived);
    }
}
