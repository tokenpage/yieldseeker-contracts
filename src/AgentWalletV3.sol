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

import {InvalidAsset, InvalidFeeTracker, YieldSeekerStorageV1} from "./AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IAgentWallet} from "./IAgentWallet.sol";
import {IAgentWalletFactory} from "./IAgentWalletFactory.sol";
import {AWKAgentWalletV3} from "./agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldSeekerAgentWalletV3
 * @notice YieldSeeker agent wallet with fee tracking and base asset management
 * @dev Extends AWKAgentWalletV3 with YieldSeeker-specific functionality. V3 pins the fee tracker it was created with
 *      and lets the tracker decide what the owner may withdraw (e.g. borrowed tokens minus borrow fees owed).
 */
contract YieldSeekerAgentWalletV3 is AWKAgentWalletV3, IAgentWallet {
    using SafeERC20 for IERC20;

    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker);

    constructor(address factory) AWKAgentWalletV3(factory) {}

    // ============ Initializers ============

    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) public virtual initializer {
        _initializeYieldSeeker(_owner, _ownerAgentIndex, _baseAsset);
    }

    function _initializeYieldSeeker(address _owner, uint256 _ownerAgentIndex, address _baseAsset) internal onlyInitializing {
        if (_baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (_baseAsset.code.length == 0) revert AWKErrors.NotAContract(_baseAsset);

        YieldSeekerStorageV1.Layout storage ys = YieldSeekerStorageV1.layout();
        ys.baseAsset = IERC20(_baseAsset);

        // Call parent initializer
        super._initializeV1(_owner, _ownerAgentIndex);
    }

    // ============ Storage Accessors ============

    /**
     * @notice Get the base asset
     * @return Base asset token
     */
    function baseAsset() public view virtual returns (IERC20) {
        return YieldSeekerStorageV1.layout().baseAsset;
    }

    /**
     * @notice Get the fee tracker
     * @return FeeTracker instance
     */
    function feeTracker() public view virtual returns (FeeTracker) {
        return YieldSeekerStorageV1.layout().feeTracker;
    }

    // ============ Synchronization ============

    function _syncFromFactory() internal virtual override {
        YieldSeekerStorageV1.Layout storage ys = YieldSeekerStorageV1.layout();

        if (address(ys.feeTracker) != address(0)) {
            AWKAgentWalletV3._syncFromFactory();
            emit SyncedFromFactory(address(adapterRegistry()), address(ys.feeTracker));
            return;
        }

        super._syncFromFactory();

        FeeTracker newTracker = IAgentWalletFactory(address(FACTORY)).feeTracker();
        if (address(newTracker) == address(0)) revert InvalidFeeTracker();
        if (address(newTracker).code.length == 0) revert InvalidFeeTracker();
        ys.feeTracker = newTracker;

        emit SyncedFromFactory(address(adapterRegistry()), address(newTracker));
    }

    // ============ Fee Collection ============

    /**
     * @notice Collect any owed fees from the wallet
     * @dev Can be called by executors during normal operations
     */
    function collectFees() external virtual onlyExecutors {
        FeeTracker tracker = feeTracker();
        uint256 owed = tracker.getFeesOwed(address(this));
        if (owed == 0) return;
        IERC20 asset = baseAsset();
        uint256 available = asset.balanceOf(address(this));
        uint256 toCollect = owed > available ? available : owed;
        if (toCollect > 0) {
            address collector = tracker.feeCollector();
            asset.safeTransfer(collector, toCollect);
            tracker.recordFeePaid(toCollect);
        }
    }

    // ============ YieldSeeker Withdrawal Functions (Fee-Aware) ============

    /**
     * @notice Calculate withdrawable balance (total balance minus fees owed)
     * @param asset Address of the asset to check (must be allowed by the fee tracker, e.g. the base asset)
     */
    function _getWithdrawableBalance(address asset) internal view virtual returns (uint256) {
        (bool allowed, uint256 feesOwed) = feeTracker().withdrawReserve(address(this), asset);
        if (!allowed) revert InvalidAsset();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > feesOwed ? balance - feesOwed : 0;
    }

    /**
     * @notice User withdraws any ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     * @dev The fee tracker validates the asset and amount allowed for withdrawal.
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external virtual override onlyOwner {
        uint256 withdrawable = _getWithdrawableBalance(asset);
        if (withdrawable < amount) revert AWKErrors.InsufficientBalance();
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of a specific ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @dev The fee tracker validates the asset and amount allowed for withdrawal.
     */
    function withdrawAllAssetToUser(address recipient, address asset) external virtual override onlyOwner {
        uint256 withdrawable = _getWithdrawableBalance(asset);
        _withdrawAsset(recipient, asset, withdrawable);
    }
}
