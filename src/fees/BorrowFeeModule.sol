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
import {FeeActions} from "./FeeActions.sol";
import {InvalidFeeRate, YieldSeekerFeeTracker} from "./FeeTracker.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

bytes32 constant BORROW_FEE = keccak256("borrow");

/**
 * @title YieldSeekerBorrowFeeModule
 * @notice Borrow fee: a yearly fee on borrowed principal, counted in the borrowed token and paid in the wallet's base
 *         asset (its collateral) at the oracle price
 * @dev Plugged into the fee tracker as BORROW_FEE; the rate comes from the owner's plan in the tracker.
 *      Lending adapters report every borrow, repay and collateral withdrawal per market with the protocol's real debt
 *      (FeeActions.DEBT_CHANGE). Each period between two reports is charged on min(principal, debt at the start of the
 *      period), so repaying directly on the protocol cannot erase the fee, and a liquidation over-charges at most the
 *      period it happens in. Repayments pay interest first, then principal. Fees are paid from the base asset after any
 *      reported action; a token without a fresh oracle price stays owed until it has one, so the wallet can always act.
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
    mapping(address wallet => mapping(address token => uint256)) public feesOwed;

    event BorrowFeeCharged(address indexed wallet, bytes32 indexed market, address indexed token, uint256 fee);
    event FeePaid(address indexed wallet, address indexed token, uint256 amount, address paidToken, uint256 paidAmount);

    constructor(YieldSeekerFeeTracker feeTracker, IYieldSeekerPriceOracle priceOracle, uint256 maxFeeRateBps) {
        if (address(feeTracker) == address(0) || address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        FEE_TRACKER = feeTracker;
        PRICE_ORACLE = priceOracle;
        MAX_FEE_RATE_BPS = maxFeeRateBps;
    }

    function onAction(bytes32 action, bytes calldata data) external returns (uint256 payment) {
        if (action == FeeActions.DEBT_CHANGE) _recordDebtChange(abi.decode(data, (FeeActions.DebtChange)));
        return _payFees();
    }

    function _recordDebtChange(FeeActions.DebtChange memory change) internal {
        _accrue(msg.sender, change.market, change.debtToken, change.debtBefore);
        DebtPosition storage position = debtPositions[msg.sender][change.market];
        if (change.borrowed > 0) {
            position.principal = (uint256(position.principal) + change.borrowed).toUint128();
            position.lastDebt = (uint256(position.lastDebt) + change.borrowed).toUint128();
            if (!isBorrowedToken[msg.sender][change.debtToken]) {
                isBorrowedToken[msg.sender][change.debtToken] = true;
                _borrowedTokens[msg.sender].push(change.debtToken);
            }
        }
        if (change.repaid > 0) {
            uint256 interest = change.debtBefore > position.principal ? change.debtBefore - position.principal : 0;
            uint256 principalRepaid = change.repaid > interest ? change.repaid - interest : 0;
            position.principal = principalRepaid >= position.principal ? 0 : position.principal - principalRepaid.toUint128();
            position.lastDebt = (change.debtBefore > change.repaid ? change.debtBefore - change.repaid : 0).toUint128();
        }
    }

    function _accrue(address wallet, bytes32 market, address token, uint256 currentDebt) internal {
        DebtPosition storage position = debtPositions[wallet][market];
        uint256 fee = _pendingFee(position);
        if (fee > 0) {
            feesOwed[wallet][token] += fee;
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

    /// @dev Pays the calling wallet's fees, token by token, from its base asset at the oracle price
    function _payFees() internal returns (uint256 paid) {
        address[] storage tokens = _borrowedTokens[msg.sender];
        if (tokens.length == 0) return 0;
        address baseAsset = address(IAgentWallet(msg.sender).baseAsset());
        uint256 available = IERC20(baseAsset).balanceOf(msg.sender);
        for (uint256 i = 0; i < tokens.length && paid < available; i++) {
            address token = tokens[i];
            uint256 owed = feesOwed[msg.sender][token];
            if (owed == 0) continue;
            uint256 owedInBaseAsset;
            try PRICE_ORACLE.quote(token, baseAsset, owed) returns (uint256 quoted) {
                owedInBaseAsset = quoted;
            } catch {}
            if (owedInBaseAsset == 0) continue;
            uint256 payment = Math.min(owedInBaseAsset, available - paid);
            uint256 covered = payment == owedInBaseAsset ? owed : Math.mulDiv(owed, payment, owedInBaseAsset);
            feesOwed[msg.sender][token] = owed - covered;
            paid += payment;
            emit FeePaid(msg.sender, token, covered, baseAsset, payment);
        }
    }

    /// @notice The fee a market has accrued since its last report (charged at the next report)
    function pendingFee(address wallet, bytes32 market) external view returns (uint256) {
        return _pendingFee(debtPositions[wallet][market]);
    }

    function borrowedTokens(address wallet) external view returns (address[] memory) {
        return _borrowedTokens[wallet];
    }

    /// @notice Borrowed tokens are accounted for here, so they may be held, swapped into and sent out
    function tracksToken(address wallet, address token) external view returns (bool) {
        return isBorrowedToken[wallet][token];
    }

    /// @notice Borrow fees are paid in the base asset as soon as the wallet holds it, so nothing is held back
    function feesHeld(address, address) external pure returns (uint256) {
        return 0;
    }
}
