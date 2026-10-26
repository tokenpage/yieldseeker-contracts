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
import {FeeActions} from "./FeeActions.sol";
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
 *      Fees are paid from the base asset as soon as the wallet holds it; what can't be paid stays owed.
 *      The rate comes from the owner's plan in the fee tracker (YIELD_FEE).
 */
contract YieldSeekerYieldFeeModule is IYieldSeekerFeeModule {
    YieldSeekerFeeTracker public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    mapping(address wallet => mapping(address target => uint256)) public costBasis;
    mapping(address wallet => uint256) public feesOwed;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);
    event FeePaid(address indexed wallet, uint256 amount);

    constructor(YieldSeekerFeeTracker feeTracker, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    function onAction(bytes32 action, bytes calldata data, address baseAsset, uint256 available) external returns (uint256 payment) {
        uint256 yield;
        if (action == FeeActions.DEPOSIT) {
            (address target, uint256 assetsIn) = abi.decode(data, (address, uint256));
            costBasis[msg.sender][target] += assetsIn;
        } else if (action == FeeActions.WITHDRAW) {
            (address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) = abi.decode(data, (address, uint256, uint256, uint256));
            yield = _releaseCostBasis(target, spent, heldBefore, assetsOut);
        } else if (action == FeeActions.SWAP) {
            (address sold,, address bought, uint256 boughtAmount) = abi.decode(data, (address, uint256, address, uint256));
            if (bought == baseAsset && sold != baseAsset) yield = boughtAmount;
        } else if (action == FeeActions.CLAIM) {
            (address token, uint256 amount) = abi.decode(data, (address, uint256));
            if (token == baseAsset) yield = amount;
        }
        uint256 owed = feesOwed[msg.sender];
        if (yield > 0) {
            uint256 fee = (yield * FEE_TRACKER.feeRateBps(YIELD_FEE, msg.sender)) / 1e4;
            owed += fee;
            emit YieldRecorded(msg.sender, yield, fee);
        }
        if (owed == 0) return 0;
        payment = Math.min(owed, available);
        feesOwed[msg.sender] = owed - payment;
        if (payment > 0) emit FeePaid(msg.sender, payment);
    }

    /// @notice The base asset may leave minus fees owed; other tokens are not this module's concern
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        if (allowed) reserved = feesOwed[wallet];
    }

    function _releaseCostBasis(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) internal returns (uint256 yield) {
        if (spent == 0 || heldBefore == 0) return 0;
        uint256 basis = costBasis[msg.sender][target];
        uint256 releasedBasis = spent >= heldBefore ? basis : Math.mulDiv(basis, spent, heldBefore);
        costBasis[msg.sender][target] = basis - releasedBasis;
        if (assetsOut > releasedBasis) yield = assetsOut - releasedBasis;
    }
}
