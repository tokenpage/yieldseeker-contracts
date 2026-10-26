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
 * @dev Adapters running in a wallet report what the wallet did to every module (the on* facts); each module decides
 *      which facts it charges for. After every action the adapter pays each module's fees due from the wallet's base
 *      asset. Everything is keyed on msg.sender (the wallet), so callers can only affect their own accounting.
 *      Rates and the fee collector come from the tracker.
 */
interface IYieldSeekerFeeModule {
    /// @notice The highest plan rate the tracker accepts for this fee type
    function MAX_FEE_RATE_BPS() external view returns (uint256);

    /// @notice Whether this fee type lets `token` leave `wallet`, and how much of it is held back for fees owed
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved);

    /// @notice Fees `wallet` owes this module, in its base asset
    function feesDue(address wallet) external view returns (uint256);

    /// @notice Record that the calling wallet paid `amount` of its base asset to the fee collector
    function recordFeePaid(uint256 amount) external;

    /// @notice The wallet put `assetsIn` of its base asset into `target` (e.g. a vault)
    function onDeposit(address target, uint256 assetsIn) external;

    /// @notice The wallet took `assetsOut` of its base asset out of `target`, spending `spent` of the `heldBefore` it held there
    function onWithdraw(address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) external;

    /// @notice The wallet swapped `soldAmount` of `sold` for `boughtAmount` of `bought`
    function onSwap(address sold, uint256 soldAmount, address bought, uint256 boughtAmount) external;

    /// @notice The wallet claimed `amount` of `token` as a reward
    function onClaim(address token, uint256 amount) external;

    /// @notice The wallet's debt of `debtToken` on `market` was `debtBefore` before it borrowed `borrowed` or repaid `repaid` (both 0 for a checkpoint)
    function onDebtChange(bytes32 market, address debtToken, uint256 debtBefore, uint256 borrowed, uint256 repaid) external;
}
