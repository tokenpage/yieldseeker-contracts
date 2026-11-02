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

error InvalidFeeRate();

/**
 * @title IYieldSeekerFeeModule
 * @notice A fee type plugged into the YieldSeekerFeeTracker (e.g. the yield fee, the borrow fee)
 * @dev The fee tracker passes every action a wallet's adapters report (see FeeActions) to every module. Each module
 *      decides what the action costs and returns what the wallet pays now; the tracker adds it up and the adapter
 *      sends it to the fee collector. Only the module's tracker may call onAction.
 *      Each module defines its own plan struct (its rates); the tracker stores plans ABI-encoded and every wallet's
 *      plan choice, and asks the module to validate each plan.
 */
interface IYieldSeekerFeeModule {
    /// @notice Whether `plan` is an ABI-encoded plan this module can charge with (within its fixed maximums)
    function isValidPlan(bytes calldata plan) external view returns (bool);

    /**
     * @notice Record an action of `wallet` and settle its fees; only callable by the module's fee tracker
     * @param action The action ID (FeeActions); unknown actions charge nothing
     * @param data The action's struct, ABI-encoded (FeeActions)
     * @param maxPayment The wallet's base asset still available for fees in this action
     * @return payment Base asset the wallet pays now (at most `maxPayment`), recorded as paid
     */
    function onAction(address wallet, bytes32 action, bytes calldata data, uint256 maxPayment) external returns (uint256 payment);

    /// @notice Whether this module accounts for `token` (besides the base asset) in `wallet`, e.g. a borrowed token
    function isAccountedToken(address wallet, address token) external view returns (bool);

    /// @notice Fees `wallet` owes this module and has not paid yet, valued in its base asset (for display; the module
    ///         collects them at the wallet's next reported action or outflow)
    function feesOwedInBaseAsset(address wallet) external view returns (uint256);
}
