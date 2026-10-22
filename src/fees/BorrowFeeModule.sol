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

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {InvalidFeeRate, YieldSeekerFeePlans} from "./FeePlans.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

bytes32 constant BORROW_FEE = keccak256("borrow");

error FeePaidExceedsOwed(uint256 owed, uint256 paid);

/**
 * @title YieldSeekerBorrowFeeModule
 * @notice Fee module for borrowing: a yearly fee on borrowed principal, owed and paid in the borrowed token
 * @dev Plugged into the fee tracker as BORROW_FEE; the rate comes from the owner's plan in the tracker.
 *      Lending adapters report every borrow, repay and collateral withdrawal per market with the protocol's real debt.
 *      Each period between two reports is charged on min(principal, debt at the start of the period), so repaying
 *      directly on the protocol cannot erase the fee, and a liquidation over-charges at most the period it happens in.
 *      Repayments pay interest first, then principal.
 *      All recording functions use msg.sender, so callers can only affect their own accounting.
 */
contract YieldSeekerBorrowFeeModule is IYieldSeekerFeeModule {
    using SafeCast for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    YieldSeekerFeePlans public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    struct DebtPosition {
        uint128 principal;
        uint128 lastDebt;
        uint64 lastAccrual;
        uint16 rateBps;
    }

    mapping(address wallet => mapping(bytes32 market => DebtPosition)) public debtPositions;
    mapping(address wallet => mapping(address token => bool)) public isBorrowedToken;
    mapping(address wallet => mapping(address token => uint256)) public feesCharged;
    mapping(address wallet => mapping(address token => uint256)) public feesPaid;

    event BorrowFeeCharged(address indexed wallet, bytes32 indexed market, address indexed token, uint256 fee);
    event FeePaid(address indexed wallet, address indexed token, uint256 amount, address paidToken, uint256 paidAmount);

    constructor(YieldSeekerFeePlans feeTracker, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    // ============ Lending Hooks ============

    /// @notice Charge the fee accrued on a market since its last report
    function checkpoint(bytes32 market, address token, uint256 currentDebt) external {
        _accrue(msg.sender, market, token, currentDebt);
    }

    function recordBorrow(bytes32 market, address token, uint256 amount, uint256 debtBefore) external {
        _accrue(msg.sender, market, token, debtBefore);
        DebtPosition storage position = debtPositions[msg.sender][market];
        position.principal = (uint256(position.principal) + amount).toUint128();
        position.lastDebt = (uint256(position.lastDebt) + amount).toUint128();
        isBorrowedToken[msg.sender][token] = true;
    }

    function recordRepay(bytes32 market, address token, uint256 repaid, uint256 debtBefore) external {
        _accrue(msg.sender, market, token, debtBefore);
        DebtPosition storage position = debtPositions[msg.sender][market];
        uint256 interest = debtBefore > position.principal ? debtBefore - position.principal : 0;
        uint256 principalRepaid = repaid > interest ? repaid - interest : 0;
        position.principal = principalRepaid >= position.principal ? 0 : position.principal - principalRepaid.toUint128();
        position.lastDebt = (debtBefore > repaid ? debtBefore - repaid : 0).toUint128();
    }

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

    /// @notice Record that the calling wallet paid `amount` of the fee owed in `token`, by sending `paidAmount` of `paidToken`
    function recordFeePaid(address token, uint256 amount, address paidToken, uint256 paidAmount) external {
        uint256 owed = feesOwed(msg.sender, token);
        if (amount > owed) revert FeePaidExceedsOwed(owed, amount);
        feesPaid[msg.sender][token] += amount;
        emit FeePaid(msg.sender, token, amount, paidToken, paidAmount);
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

    /// @notice Borrowed tokens may leave minus the fees owed in them; other tokens are not this module's concern
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        if (!isBorrowedToken[wallet][token]) return (false, 0);
        return (true, feesOwed(wallet, token));
    }
}
