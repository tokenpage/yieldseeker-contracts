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
 *      decides what the action costs and returns what the wallet pays now; the adapter sends the total to the fee
 *      collector. Everything is keyed on msg.sender (the wallet), so callers can only affect their own accounting.
 *      Rates and the fee collector come from the tracker.
 */
interface IYieldSeekerFeeModule {
    /// @notice The highest plan rate the tracker accepts for this fee type
    function MAX_FEE_RATE_BPS() external view returns (uint256);

    /// @notice Whether this fee type lets `token` leave `wallet`, and how much of it is held back for fees owed
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved);

    /**
     * @notice Record an action of the calling wallet and settle its fees
     * @param action The action ID (FeeActions); unknown actions charge nothing
     * @param data The action's ABI-encoded data (FeeActions)
     * @param baseAsset The wallet's base asset
     * @param available The base asset the wallet can pay with
     * @return payment The base asset the wallet must send to the fee collector now (at most `available`), recorded as paid
     */
    function onAction(bytes32 action, bytes calldata data, address baseAsset, uint256 available) external returns (uint256 payment);
}
