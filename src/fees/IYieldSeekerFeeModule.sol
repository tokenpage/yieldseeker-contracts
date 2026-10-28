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

/**
 * @title IYieldSeekerFeeModule
 * @notice A fee type plugged into the YieldSeekerFeeTracker (e.g. the yield fee, the borrow fee)
 * @dev After every action, the adapter running in a wallet reports it to every module (see FeeActions). Each module
 *      decides what the action costs and returns what the wallet pays now, which the adapter sends to the fee
 *      collector before calling the next module. Everything is keyed on msg.sender (the wallet), so callers can only
 *      affect their own accounting. Rates come from the wallet's plans in the tracker.
 */
interface IYieldSeekerFeeModule {
    /// @notice The highest plan rate the tracker accepts for this fee type
    function MAX_FEE_RATE_BPS() external view returns (uint256);

    /**
     * @notice Record an action of the calling wallet and settle its fees
     * @param action The action ID (FeeActions); unknown actions charge nothing
     * @param data The action's struct, ABI-encoded (FeeActions)
     * @return payment Base asset the wallet must send to the fee collector now (at most its balance), recorded as paid
     */
    function onAction(bytes32 action, bytes calldata data) external returns (uint256 payment);

    /// @notice Whether this module accounts for `token` (besides the base asset) in `wallet`, e.g. a borrowed token
    function tracksToken(address wallet, address token) external view returns (bool);

    /// @notice How much `token` `wallet` must keep for fees owed to this module
    function feesHeld(address wallet, address token) external view returns (uint256);
}
