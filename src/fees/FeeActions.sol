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
 * @title FeeActions
 * @notice What adapters report to fee modules: an action ID and its ABI-encoded data
 * @dev New actions are added here; fee modules ignore actions they don't know, so deployed modules keep working.
 */
library FeeActions {
    /// @dev abi.encode(address target, uint256 assetsIn): base asset put into `target` (e.g. a vault)
    bytes32 internal constant DEPOSIT = keccak256("deposit");

    /// @dev abi.encode(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut): base asset taken out of
    ///      `target`, spending `spent` of the `heldBefore` the wallet held there (shares, or balance for rebasing vaults)
    bytes32 internal constant WITHDRAW = keccak256("withdraw");

    /// @dev abi.encode(address sold, uint256 soldAmount, address bought, uint256 boughtAmount)
    bytes32 internal constant SWAP = keccak256("swap");

    /// @dev abi.encode(address token, uint256 amount): a reward claimed into the wallet
    bytes32 internal constant CLAIM = keccak256("claim");

    /// @dev abi.encode(bytes32 market, address debtToken, uint256 debtBefore, uint256 borrowed, uint256 repaid):
    ///      a borrow (`borrowed` > 0), a repay (`repaid` > 0) or a checkpoint (both 0) on a lending market
    bytes32 internal constant DEBT_CHANGE = keccak256("debtChange");
}
