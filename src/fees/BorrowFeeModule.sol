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
import {IYieldSeekerPriceOracle} from "../PriceOracle.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {InvalidFeeRate, YieldSeekerFeeTracker} from "./FeeTracker.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

bytes32 constant BORROW_FEE = keccak256("borrow");

error FeePaidExceedsDue(uint256 due, uint256 paid);

/**
 * @title YieldSeekerBorrowFeeModule
 * @notice Borrow fee: a yearly fee on borrowed principal, counted in the borrowed token and paid in the wallet's base
 *         asset (its collateral) at the oracle price
 * @dev Plugged into the fee tracker as BORROW_FEE; the rate comes from the owner's plan in the tracker.
 *      Lending adapters report every borrow, repay and collateral withdrawal per market with the protocol's real debt
 *      (onDebtChange). Each period between two reports is charged on min(principal, debt at the start of the period),
 *      so repaying directly on the protocol cannot erase the fee, and a liquidation over-charges at most the period it
 *      happens in. Repayments pay interest first, then principal. A token without a fresh oracle price is left out of
 *      the fees due until it has one, so the wallet can always act.
 *      All functions use msg.sender, so callers can only affect their own accounting.
 */
contract YieldSeekerBorrowFeeModule is IYieldSeekerFeeModule {
    using SafeCast for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    YieldSeekerFeeTracker public immutable FEE_TRACKER;
    IYieldSeekerPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable MAX_FEE_RATE_BPS;

    struct DebtPosition {
        uint128 principal;
        uint128 lastDebt;
        uint64 lastAccrual;
        uint16 rateBps;
    }

    mapping(address wallet => mapping(bytes32 market => DebtPosition)) public debtPositions;
    mapping(address wallet => mapping(address token => bool)) public isBorrowedToken;
    mapping(address wallet => address[]) internal _borrowedTokens;
    mapping(address wallet => mapping(address token => uint256)) public feesCharged;
    mapping(address wallet => mapping(address token => uint256)) public feesPaid;

    event BorrowFeeCharged(address indexed wallet, bytes32 indexed market, address indexed token, uint256 fee);
    event FeePaid(address indexed wallet, address indexed token, uint256 amount, address paidToken, uint256 paidAmount);

    constructor(YieldSeekerFeeTracker feeTracker, IYieldSeekerPriceOracle priceOracle, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0) || address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        PRICE_ORACLE = priceOracle;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    // ============ Facts ============

    function onDebtChange(bytes32 market, address debtToken, uint256 debtBefore, uint256 borrowed, uint256 repaid) external {
        _accrue(msg.sender, market, debtToken, debtBefore);
        DebtPosition storage position = debtPositions[msg.sender][market];
        if (borrowed > 0) {
            position.principal = (uint256(position.principal) + borrowed).toUint128();
            position.lastDebt = (uint256(position.lastDebt) + borrowed).toUint128();
            if (!isBorrowedToken[msg.sender][debtToken]) {
                isBorrowedToken[msg.sender][debtToken] = true;
                _borrowedTokens[msg.sender].push(debtToken);
            }
        }
        if (repaid > 0) {
            uint256 interest = debtBefore > position.principal ? debtBefore - position.principal : 0;
            uint256 principalRepaid = repaid > interest ? repaid - interest : 0;
            position.principal = principalRepaid >= position.principal ? 0 : position.principal - principalRepaid.toUint128();
            position.lastDebt = (debtBefore > repaid ? debtBefore - repaid : 0).toUint128();
        }
    }

    function onDeposit(address, uint256) external {}

    function onWithdraw(address, uint256, uint256, uint256) external {}

    function onSwap(address, uint256, address, uint256) external {}

    function onClaim(address, uint256) external {}

    function _accrue(address wallet, bytes32 market, address token, uint256 currentDebt) internal {
        DebtPosition storage position = debtPositions[wallet][market];
        uint256 fee = _pendingFee(position);
        if (fee > 0) {
            feesCharged[wallet][token] += fee;
            emit BorrowFeeCharged(wallet, market, token, fee);
        }
        if (currentDebt < position.principal) position.principal = currentDebt.toUint128();
        position.lastDebt = currentDebt.toUint128();
        position.lastAccrual = uint64(block.timestamp);
        position.rateBps = FEE_TRACKER.feeRateBps(BORROW_FEE, wallet).toUint16();
    }

    function _pendingFee(DebtPosition memory position) internal view returns (uint256) {
        if (position.lastAccrual == 0) return 0;
        uint256 accruingPrincipal = position.principal < position.lastDebt ? position.principal : position.lastDebt;
        return (accruingPrincipal * position.rateBps * (block.timestamp - position.lastAccrual)) / (SECONDS_PER_YEAR * 1e4);
    }

    // ============ Payments ============

    function feesDue(address wallet) external view returns (uint256 due) {
        address baseAsset = address(IAgentWallet(wallet).baseAsset());
        address[] storage tokens = _borrowedTokens[wallet];
        for (uint256 i = 0; i < tokens.length; i++) {
            (, uint256 owedInBaseAsset) = _owed(wallet, tokens[i], baseAsset);
            due += owedInBaseAsset;
        }
    }

    /// @notice Record that the calling wallet paid `amount` of its base asset, covering its borrowed tokens' fees in order
    function recordFeePaid(uint256 amount) external {
        address baseAsset = address(IAgentWallet(msg.sender).baseAsset());
        address[] storage tokens = _borrowedTokens[msg.sender];
        uint256 remaining = amount;
        for (uint256 i = 0; i < tokens.length && remaining > 0; i++) {
            (uint256 owed, uint256 owedInBaseAsset) = _owed(msg.sender, tokens[i], baseAsset);
            if (owedInBaseAsset == 0) continue;
            uint256 payment = remaining < owedInBaseAsset ? remaining : owedInBaseAsset;
            uint256 covered = payment == owedInBaseAsset ? owed : Math.mulDiv(owed, payment, owedInBaseAsset);
            feesPaid[msg.sender][tokens[i]] += covered;
            remaining -= payment;
            emit FeePaid(msg.sender, tokens[i], covered, baseAsset, payment);
        }
        if (remaining > 0) revert FeePaidExceedsDue(amount - remaining, amount);
    }

    /// @dev Fees owed in `token`, and their value in `baseAsset` (0 while the oracle has no fresh price)
    function _owed(address wallet, address token, address baseAsset) internal view returns (uint256 owed, uint256 owedInBaseAsset) {
        owed = feesOwed(wallet, token);
        if (owed == 0) return (0, 0);
        try PRICE_ORACLE.quote(token, baseAsset, owed) returns (uint256 quoted) {
            owedInBaseAsset = quoted;
        } catch {}
    }

    // ============ Views ============

    function feesOwed(address wallet, address token) public view returns (uint256) {
        uint256 charged = feesCharged[wallet][token];
        uint256 paid = feesPaid[wallet][token];
        return charged > paid ? charged - paid : 0;
    }

    /// @notice The fee a market has accrued since its last report (charged at the next report)
    function pendingFee(address wallet, bytes32 market) external view returns (uint256) {
        return _pendingFee(debtPositions[wallet][market]);
    }

    function borrowedTokens(address wallet) external view returns (address[] memory) {
        return _borrowedTokens[wallet];
    }

    /// @notice Borrowed tokens may leave in full; their fees are paid in the base asset
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = isBorrowedToken[wallet][token];
    }
}
