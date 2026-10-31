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
import {YieldSeekerFeeTracker} from "./FeeTracker.sol";
import {IYieldSeekerFeeModule, InvalidFeeRate} from "./IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
 *      The rate comes from the wallet's YIELD_FEE plan in the fee tracker (a Plan, at most MAX_FEE_RATE_BPS).
 */
contract YieldSeekerYieldFeeModule is IYieldSeekerFeeModule {
    YieldSeekerFeeTracker public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    struct Plan {
        uint256 rateBps;
    }

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

    function onAction(bytes32 action, bytes calldata data) external returns (uint256 payment) {
        uint256 yield;
        address baseAsset;
        if (action == FeeActions.DEPOSIT) {
            FeeActions.Deposit memory deposit = abi.decode(data, (FeeActions.Deposit));
            costBasis[msg.sender][deposit.target] += deposit.assetsIn;
        } else if (action == FeeActions.WITHDRAW) {
            yield = _releaseCostBasis(abi.decode(data, (FeeActions.Withdraw)));
        } else if (action == FeeActions.SWAP) {
            FeeActions.Swap memory swap = abi.decode(data, (FeeActions.Swap));
            baseAsset = _baseAsset();
            if (swap.bought == baseAsset && swap.sold != baseAsset) yield = swap.boughtAmount;
        } else if (action == FeeActions.CLAIM) {
            FeeActions.Claim memory claim = abi.decode(data, (FeeActions.Claim));
            baseAsset = _baseAsset();
            if (claim.token == baseAsset) yield = claim.amount;
        }
        uint256 owed = feesOwed[msg.sender];
        if (yield > 0) {
            uint256 fee = (yield * walletPlan(msg.sender).rateBps) / 1e4;
            owed += fee;
            emit YieldRecorded(msg.sender, yield, fee);
        }
        if (owed == 0) return 0;
        if (baseAsset == address(0)) baseAsset = _baseAsset();
        payment = Math.min(owed, IERC20(baseAsset).balanceOf(msg.sender));
        feesOwed[msg.sender] = owed - payment;
        if (payment > 0) emit FeePaid(msg.sender, payment);
    }

    function isValidPlan(bytes calldata plan) external view returns (bool) {
        return plan.length == 32 && abi.decode(plan, (Plan)).rateBps <= MAX_FEE_RATE_BPS;
    }

    /// @notice The wallet's yield fee plan (rate 0 until YIELD_FEE has plans)
    function walletPlan(address wallet) public view returns (Plan memory plan) {
        bytes memory data = FEE_TRACKER.walletPlan(wallet, YIELD_FEE);
        if (data.length > 0) plan = abi.decode(data, (Plan));
    }

    /// @notice The base asset is tracked by the fee tracker itself; this module accounts for no other token
    function tracksToken(address, address) external pure returns (bool) {
        return false;
    }

    /// @notice Fees owed are held back from the base asset
    function feesHeld(address wallet, address token) external view returns (uint256) {
        return token == address(IAgentWallet(wallet).baseAsset()) ? feesOwed[wallet] : 0;
    }

    function _releaseCostBasis(FeeActions.Withdraw memory withdrawal) internal returns (uint256 yield) {
        if (withdrawal.spent == 0 || withdrawal.heldBefore == 0) return 0;
        uint256 basis = costBasis[msg.sender][withdrawal.target];
        uint256 releasedBasis = withdrawal.spent >= withdrawal.heldBefore ? basis : Math.mulDiv(basis, withdrawal.spent, withdrawal.heldBefore);
        costBasis[msg.sender][withdrawal.target] = basis - releasedBasis;
        if (withdrawal.assetsOut > releasedBasis) yield = withdrawal.assetsOut - releasedBasis;
    }

    function _baseAsset() internal view returns (address) {
        return address(IAgentWallet(msg.sender).baseAsset());
    }
}
