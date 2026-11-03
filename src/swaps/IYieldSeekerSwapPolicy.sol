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

error SwapNotAllowed(address sellToken, address buyToken);

/**
 * @title IYieldSeekerSwapPolicy
 * @notice The swap rules of one agent type: which swaps its wallets may make, and what each one counts as for fees
 * @dev The wallet factory holds one policy per agent profile (swapPolicy), set by the timelock and replaceable on its
 *      own. Swap adapters (one per DEX, shared by every agent type) ask the wallet's policy before and after a swap.
 */
interface IYieldSeekerSwapPolicy {
    /// @notice Reverts unless `wallet` may sell `sellToken` for `buyToken`
    function checkSwap(address wallet, address sellToken, address buyToken) external view;

    /**
     * @notice Reverts if a finished swap breaks a rule (e.g. a price floor)
     * @return action The fee action to report the swap as (FeeActions.REWARD_SALE or FeeActions.SWAP)
     */
    function checkSwapResult(address wallet, address sellToken, uint256 soldAmount, address buyToken, uint256 boughtAmount) external view returns (bytes32 action);
}
