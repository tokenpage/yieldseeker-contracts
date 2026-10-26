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

bytes32 constant YIELD_FEE = keccak256("yield");

/**
 * @title YieldSeekerYieldFeeModule
 * @notice Yield fee: a share of the yield a wallet realises in its base asset, for every agent type
 * @dev Each deposit target keeps only its cost basis, the base asset put in. A withdrawal of `spent` out of the
 *      `heldBefore` the wallet held there (vault shares, or the balance for rebasing vaults) releases the same fraction
 *      of the cost basis, and anything received above it is yield. Rewards paid as vault shares or rebasing tokens
 *      have no cost basis, so they are charged when withdrawn. Rewards claimed in the base asset, and the base asset
 *      received for selling any other token, are yield when they arrive.
 *      All functions use msg.sender, so callers can only affect their own accounting.
 *      The rate comes from the owner's plan in the fee tracker (YIELD_FEE).
 */
contract YieldSeekerYieldFeeModule is IYieldSeekerFeeModule {
    YieldSeekerFeeTracker public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    mapping(address wallet => mapping(address target => uint256)) public costBasis;
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

    // ============ Facts ============

    function onDeposit(address target, uint256 assetsIn) external {
        costBasis[msg.sender][target] += assetsIn;
    }

    function onWithdraw(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) external {
        if (spent == 0 || heldBefore == 0) return;
        uint256 basis = costBasis[msg.sender][target];
        uint256 releasedBasis = spent >= heldBefore ? basis : Math.mulDiv(basis, spent, heldBefore);
        costBasis[msg.sender][target] = basis - releasedBasis;
        if (assetsOut > releasedBasis) _chargeFee(msg.sender, assetsOut - releasedBasis);
    }

    function onSwap(address sold, uint256, address bought, uint256 boughtAmount) external {
        address baseAsset = address(IAgentWallet(msg.sender).baseAsset());
        if (bought == baseAsset && sold != baseAsset) _chargeFee(msg.sender, boughtAmount);
    }

    function onClaim(address token, uint256 amount) external {
        if (token == address(IAgentWallet(msg.sender).baseAsset())) _chargeFee(msg.sender, amount);
    }

    function onDebtChange(bytes32, address, uint256, uint256, uint256) external {}

    // ============ Payments ============

    function feesDue(address wallet) public view returns (uint256) {
        uint256 charged = feesCharged[wallet];
        uint256 paid = feesPaid[wallet];
        return charged > paid ? charged - paid : 0;
    }

    function recordFeePaid(uint256 amount) external {
        feesPaid[msg.sender] += amount;
        emit FeePaid(msg.sender, amount);
    }

    /// @notice The base asset may leave minus fees not yet paid; other tokens are not this module's concern
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        if (allowed) reserved = feesDue(wallet);
    }

    function _chargeFee(address wallet, uint256 yield) internal {
        uint256 fee = (yield * FEE_TRACKER.feeRateBps(YIELD_FEE, wallet)) / 1e4;
        feesCharged[wallet] += fee;
        emit YieldRecorded(wallet, yield, fee);
    }
}
