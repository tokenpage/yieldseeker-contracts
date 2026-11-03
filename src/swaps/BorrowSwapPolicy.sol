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
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {IAgentWallet} from "../IAgentWallet.sol";
import {IYieldSeekerPriceOracle} from "../PriceOracle.sol";
import {IYieldSeekerSwapSellPolicy} from "../adapters/SwapSellPolicy.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../fees/BorrowFeeModule.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {SwapNotAllowed} from "./IYieldSeekerSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy} from "./VaultSwapPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidSlippage(uint256 maxSlippageBps);
error SwapBelowOraclePrice(uint256 received, uint256 minimum);
error SwapAboveDebt(uint256 held, uint256 debt);

/**
 * @title YieldSeekerBorrowSwapPolicy
 * @notice Borrow agents sell reward tokens for the base asset, and sell the base asset (their collateral) for a token
 *         they borrowed, at most MAX_SLIPPAGE_BPS below the price oracle and only up to what they owe in it
 * @dev Buying a borrowed token is for repaying: after the swap the wallet may hold at most its debt in that token as
 *      of each market's last report (the BORROW_FEE module's tokenDebt; checkpoint first to include fresh interest).
 *      Borrowed tokens can never be sold, so collateral can't be drained with round trips, and across linked wallets
 *      each wallet can turn at most its own debt's worth of collateral into the token. Selling the base asset is a
 *      trade (FeeActions.SWAP), not yield.
 */
contract YieldSeekerBorrowSwapPolicy is YieldSeekerVaultSwapPolicy {
    IYieldSeekerPriceOracle public immutable PRICE_ORACLE;
    uint256 public immutable MAX_SLIPPAGE_BPS;

    constructor(IYieldSeekerSwapSellPolicy sellPolicy, IYieldSeekerPriceOracle priceOracle, uint256 maxSlippageBps) YieldSeekerVaultSwapPolicy(sellPolicy) {
        if (address(priceOracle) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxSlippageBps >= 1e4) revert InvalidSlippage(maxSlippageBps);
        PRICE_ORACLE = priceOracle;
        MAX_SLIPPAGE_BPS = maxSlippageBps;
    }

    function checkSwap(address wallet, address sellToken, address buyToken) public view override {
        if (sellToken == address(IAgentWallet(wallet).baseAsset())) {
            if (!_isBorrowedToken(wallet, buyToken)) revert SwapNotAllowed(sellToken, buyToken);
            return;
        }
        if (_isBorrowedToken(wallet, sellToken)) revert SwapNotAllowed(sellToken, buyToken);
        _checkRewardSale(wallet, sellToken, buyToken);
    }

    function checkSwapResult(address wallet, address sellToken, uint256 soldAmount, address buyToken, uint256 boughtAmount) public view override returns (bytes32) {
        if (sellToken != address(IAgentWallet(wallet).baseAsset())) return FeeActions.REWARD_SALE;
        uint256 minimum = (PRICE_ORACLE.quote(sellToken, buyToken, soldAmount) * (1e4 - MAX_SLIPPAGE_BPS)) / 1e4;
        if (boughtAmount < minimum) revert SwapBelowOraclePrice(boughtAmount, minimum);
        uint256 held = IERC20(buyToken).balanceOf(wallet);
        uint256 debt = _borrowFees(wallet).tokenDebt(wallet, buyToken);
        if (held > debt) revert SwapAboveDebt(held, debt);
        return FeeActions.SWAP;
    }

    function _isBorrowedToken(address wallet, address token) internal view returns (bool) {
        YieldSeekerBorrowFeeModule borrowFees = _borrowFees(wallet);
        return address(borrowFees) != address(0) && borrowFees.isAccountedToken(wallet, token);
    }

    function _borrowFees(address wallet) internal view returns (YieldSeekerBorrowFeeModule) {
        return YieldSeekerBorrowFeeModule(address(IAgentWallet(wallet).feeTracker().feeModules(BORROW_FEE)));
    }
}
