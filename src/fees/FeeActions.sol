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
pragma solidity 0.8.38;

/**
 * @title FeeActions
 * @notice What adapters report to fee modules: an action ID and its data, ABI-encoded from the action's struct
 * @dev New actions are added here as an ID and a struct; fee modules ignore actions they don't know, so deployed
 *      modules keep working. Never change an existing struct: add a new action instead.
 */
library FeeActions {
    bytes32 internal constant DEPOSIT = keccak256("deposit");

    /// @param target Where the base asset went (e.g. a vault)
    /// @param assetsIn Base asset put in
    struct Deposit {
        address target;
        uint256 assetsIn;
    }

    bytes32 internal constant WITHDRAW = keccak256("withdraw");

    /// @param target Where the base asset came from
    /// @param spent What the wallet gave up there (vault shares, or balance for rebasing vaults)
    /// @param heldBefore What the wallet held there before, in the same unit as `spent`
    /// @param assetsOut Base asset received
    struct Withdraw {
        address target;
        uint256 spent;
        uint256 heldBefore;
        uint256 assetsOut;
    }

    /// @notice A trade (e.g. collateral sold for a borrowed token); not yield
    bytes32 internal constant SWAP = keccak256("swap");

    /// @notice A reward token sold for the base asset; same data as SWAP
    bytes32 internal constant REWARD_SALE = keccak256("rewardSale");

    struct Swap {
        address sold;
        uint256 soldAmount;
        address bought;
        uint256 boughtAmount;
    }

    bytes32 internal constant CLAIM = keccak256("claim");

    /// @param token The reward token claimed into the wallet
    struct Claim {
        address token;
        uint256 amount;
    }

    bytes32 internal constant DEBT_CHANGE = keccak256("debtChange");

    /// @notice A borrow (`borrowed` > 0), a repay (`repaid` > 0), or a collateral withdrawal or checkpoint (both 0) on a
    ///         lending market
    /// @param market The market's registry target (the lending adapter's `marketTarget`)
    /// @param debtToken The market's debt token
    /// @param debtBefore The market's real debt before the action
    /// @param borrowed Debt token received by this borrow
    /// @param repaid Debt token paid back by this repay
    /// @param debtPriceInBaseAsset Base asset units worth one debt unit (raw token units, scaled by 1e36), from the
    ///        lending market's own oracle; 0 when the market has no debt before or after the action, or when the
    ///        market's price is zero (never on a borrow)
    struct DebtChange {
        address market;
        address debtToken;
        uint256 debtBefore;
        uint256 borrowed;
        uint256 repaid;
        uint256 debtPriceInBaseAsset;
    }

    bytes32 internal constant TRANSFER_OUT = keccak256("transferOut");

    /// @notice Tokens about to leave the wallet (an owner withdrawal or a transfer to another wallet of the same owner);
    ///         reported first so every module settles what it is owed before the funds go
    /// @param amount The amount requested; for an owner's withdraw-all, the whole balance before fees are paid
    struct TransferOut {
        address token;
        address to;
        uint256 amount;
    }
}
