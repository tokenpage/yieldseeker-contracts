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
import {InvalidFeeRate, YieldSeekerFeeTracker} from "./FeeTracker.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

bytes32 constant VAULT_FEE = keccak256("vault");

/**
 * @title YieldSeekerVaultFeeModule
 * @notice Vault fee: a share of the yield a wallet realises in its base asset
 * @dev Each vault position keeps only its cost basis, the base asset put in. A withdrawal of `spent` out of the
 *      `heldBefore` the wallet held (vault shares, or the balance for rebasing vaults) releases the same fraction of
 *      the cost basis, and anything received above it is yield. Rewards paid as vault shares or rebasing tokens have no
 *      cost basis, so they are charged when withdrawn. Rewards in the base asset and the base asset received for
 *      selling a reward token are yield when they arrive. The adapters pay each fee when it is charged.
 *      All recording functions use msg.sender, so callers can only affect their own accounting.
 *      The rate comes from the owner's plan in the fee tracker (VAULT_FEE).
 */
contract YieldSeekerVaultFeeModule is IYieldSeekerFeeModule {
    YieldSeekerFeeTracker public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    mapping(address wallet => mapping(address vault => uint256)) public costBasis;
    mapping(address wallet => uint256) public feesCharged;
    mapping(address wallet => uint256) public feesPaid;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);
    event FeePaid(address indexed wallet, uint256 amount);

    constructor(YieldSeekerFeeTracker feeTracker, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    /// @notice Record base asset put into a vault
    function recordDeposit(address vault, uint256 assetsDeposited) external {
        costBasis[msg.sender][vault] += assetsDeposited;
    }

    /**
     * @notice Record a withdrawal from a vault and charge the fee on the yield
     * @param vault The vault address
     * @param spent The vault shares redeemed, or the balance withdrawn for rebasing vaults
     * @param heldBefore The vault shares, or the balance for rebasing vaults, the wallet held before the withdrawal
     * @param assetsReceived The base asset received
     */
    function recordWithdraw(address vault, uint256 spent, uint256 heldBefore, uint256 assetsReceived) external {
        if (spent == 0 || heldBefore == 0) return;
        uint256 basis = costBasis[msg.sender][vault];
        uint256 releasedBasis = spent >= heldBefore ? basis : Math.mulDiv(basis, spent, heldBefore);
        costBasis[msg.sender][vault] = basis - releasedBasis;
        if (assetsReceived > releasedBasis) _chargeFee(msg.sender, assetsReceived - releasedBasis);
    }

    /// @notice Record base asset yield received outside a vault withdrawal (a base asset reward, or a reward token sold)
    function recordYield(uint256 amount) external {
        _chargeFee(msg.sender, amount);
    }

    /// @notice Record a fee payment
    function recordFeePaid(uint256 amount) external {
        feesPaid[msg.sender] += amount;
        emit FeePaid(msg.sender, amount);
    }

    function feesOwed(address wallet) public view returns (uint256) {
        uint256 charged = feesCharged[wallet];
        uint256 paid = feesPaid[wallet];
        return charged > paid ? charged - paid : 0;
    }

    /// @notice The base asset may leave minus fees owed; other tokens are not this module's concern
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        if (allowed) reserved = feesOwed(wallet);
    }

    function _chargeFee(address wallet, uint256 yield) internal {
        uint256 fee = (yield * FEE_TRACKER.feeRateBps(VAULT_FEE, wallet)) / 1e4;
        feesCharged[wallet] += fee;
        emit YieldRecorded(wallet, yield, fee);
    }
}
