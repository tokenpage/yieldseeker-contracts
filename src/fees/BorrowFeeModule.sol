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
import {FeeActions} from "./FeeActions.sol";
import {YieldSeekerFeeTracker} from "./FeeTracker.sol";
import {IYieldSeekerFeeModule, InvalidFeeRate} from "./IYieldSeekerFeeModule.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

bytes32 constant BORROW_FEE = keccak256("borrow");

/**
 * @title YieldSeekerBorrowFeeModule
 * @notice Borrow fee: a yearly fee on borrowed principal, valued in the wallet's base asset (its collateral) with the
 *         lending market's own price and paid from the base asset
 * @dev Plugged into the fee tracker as BORROW_FEE; the yearly rate comes from the wallet's plan in the tracker (a Plan,
 *      at most MAX_FEE_RATE_BPS).
 *      Lending adapters report every borrow, repay, collateral withdrawal and checkpoint per market with the
 *      protocol's real debt and the market's price for it (FeeActions.DEBT_CHANGE). Each period between two reports
 *      is charged on min(principal, debt at the start of the period), so repaying directly on the protocol cannot
 *      erase the fee; after a debt change outside the adapters (e.g. a liquidation) the period runs until the next
 *      report, so the operator checkpoints the market. A report without a price (the market has no debt left, e.g.
 *      it was repaid outside the adapters) values the period with the market's last reported price. Repayments pay
 *      interest first, then principal. Fees round up. The fee is converted to the base asset when it is charged, then
 *      paid from the base asset at the first reported action or outflow that finds some. Only the fee tracker
 *      reports actions (onAction), for the wallet that reported them to it.
 */
contract YieldSeekerBorrowFeeModule is IYieldSeekerFeeModule {
    using SafeCast for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    bytes32 public constant FEE_TYPE = BORROW_FEE;
    address public immutable FEE_TRACKER;
    uint256 public immutable MAX_FEE_RATE_BPS;

    struct Plan {
        uint256 rateBps;
    }

    struct DebtPosition {
        uint128 principal;
        uint128 lastDebt;
        uint64 lastAccrual;
        uint192 lastPrice;
    }

    mapping(address wallet => mapping(bytes32 market => DebtPosition)) public debtPositions;
    mapping(address wallet => mapping(address token => bool)) public isBorrowedToken;
    mapping(address wallet => uint256) public feesOwed;

    event BorrowFeeCharged(address indexed wallet, bytes32 indexed market, address indexed debtToken, uint256 fee, uint256 feeInBaseAsset);
    event FeePaid(address indexed wallet, uint256 amount);

    constructor(YieldSeekerFeeTracker feeTracker, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = address(feeTracker);
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    function onAction(address wallet, bytes32 action, bytes calldata data, uint256 maxPayment) external returns (uint256 payment) {
        if (msg.sender != FEE_TRACKER) revert AWKErrors.Unauthorized(msg.sender);
        if (action == FeeActions.DEBT_CHANGE) _recordDebtChange(wallet, abi.decode(data, (FeeActions.DebtChange)));
        uint256 owed = feesOwed[wallet];
        if (owed == 0) return 0;
        payment = Math.min(owed, maxPayment);
        feesOwed[wallet] = owed - payment;
        if (payment > 0) emit FeePaid(wallet, payment);
    }

    function _recordDebtChange(address wallet, FeeActions.DebtChange memory change) internal {
        _accrue(wallet, change);
        DebtPosition storage position = debtPositions[wallet][change.market];
        if (change.borrowed > 0) {
            position.principal = (uint256(position.principal) + change.borrowed).toUint128();
            position.lastDebt = (uint256(position.lastDebt) + change.borrowed).toUint128();
            isBorrowedToken[wallet][change.debtToken] = true;
        }
        if (change.repaid > 0) {
            uint256 interest = change.debtBefore > position.principal ? change.debtBefore - position.principal : 0;
            uint256 principalRepaid = change.repaid > interest ? change.repaid - interest : 0;
            position.principal = principalRepaid >= position.principal ? 0 : position.principal - principalRepaid.toUint128();
            position.lastDebt = (change.debtBefore > change.repaid ? change.debtBefore - change.repaid : 0).toUint128();
        }
    }

    /// @dev Charges the period since the last report, valued in the base asset with the market's price at this report
    ///      (or the last one reported, when this report has none)
    function _accrue(address wallet, FeeActions.DebtChange memory change) internal {
        DebtPosition storage position = debtPositions[wallet][change.market];
        uint256 fee = _pendingFee(wallet, position);
        if (change.debtPriceInBaseAsset > 0) position.lastPrice = change.debtPriceInBaseAsset.toUint192();
        if (fee > 0) {
            uint256 feeInBaseAsset = Math.mulDiv(fee, position.lastPrice, 1e36, Math.Rounding.Ceil);
            feesOwed[wallet] += feeInBaseAsset;
            emit BorrowFeeCharged(wallet, change.market, change.debtToken, fee, feeInBaseAsset);
        }
        if (change.debtBefore < position.principal) position.principal = change.debtBefore.toUint128();
        position.lastDebt = change.debtBefore.toUint128();
        position.lastAccrual = uint64(block.timestamp);
    }

    function _pendingFee(address wallet, DebtPosition memory position) internal view returns (uint256) {
        if (position.lastAccrual == 0) return 0;
        uint256 accruingPrincipal = position.principal < position.lastDebt ? position.principal : position.lastDebt;
        return Math.mulDiv(accruingPrincipal, walletPlan(wallet).rateBps * (block.timestamp - position.lastAccrual), SECONDS_PER_YEAR * 1e4, Math.Rounding.Ceil);
    }

    /// @notice The fee a market has accrued since its last report, in the debt token (charged at the next report)
    function pendingFee(address wallet, bytes32 market) external view returns (uint256) {
        return _pendingFee(wallet, debtPositions[wallet][market]);
    }

    function isValidPlan(bytes calldata plan) external view returns (bool) {
        return plan.length == 32 && abi.decode(plan, (Plan)).rateBps <= MAX_FEE_RATE_BPS;
    }

    /// @notice The wallet's borrow fee plan (rate 0 until BORROW_FEE has plans)
    function walletPlan(address wallet) public view returns (Plan memory plan) {
        bytes memory data = YieldSeekerFeeTracker(FEE_TRACKER).walletPlan(wallet, BORROW_FEE);
        if (data.length > 0) plan = abi.decode(data, (Plan));
    }

    /// @notice Borrowed tokens are accounted for here, so they may be held, swapped into and sent out
    function isAccountedToken(address wallet, address token) external view returns (bool) {
        return isBorrowedToken[wallet][token];
    }

    /// @notice Borrow fees charged and not paid yet (already in the base asset)
    function feesOwedInBaseAsset(address wallet) external view returns (uint256) {
        return feesOwed[wallet];
    }
}
