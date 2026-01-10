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

import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IAgentWallet} from "./IAgentWallet.sol";
import {IAgentWalletFactory} from "./IAgentWalletFactory.sol";
import {AWKAgentWalletV1} from "./agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidAsset();
error InvalidFeeTracker();

/**
 * @title YieldSeekerStorageV1
 * @notice YieldSeeker-specific storage for base asset and fee tracking
 * @dev Uses a different namespace than AWK to avoid collisions
 */
library YieldSeekerStorageV1 {
    /// @custom:storage-location erc7201:yieldseeker.agentwallet.extensions.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.extensions.v1");

    struct Layout {
        IERC20 baseAsset;
        FeeTracker feeTracker;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}

/**
 * @title YieldSeekerAgentWalletV1
 * @notice YieldSeeker agent wallet with fee tracking and base asset management
 * @dev Extends AWKAgentWalletV1 with YieldSeeker-specific functionality
 */
contract YieldSeekerAgentWalletV1 is AWKAgentWalletV1, IAgentWallet {
    using SafeERC20 for IERC20;

    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker);

    constructor(address factory) AWKAgentWalletV1(factory) {}

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
    function baseAsset() public view returns (IERC20) {
        return YieldSeekerStorageV1.layout().baseAsset;
    }

    /**
     * @notice Get the fee tracker
     * @return FeeTracker instance
     */
    function feeTracker() public view returns (FeeTracker) {
        return YieldSeekerStorageV1.layout().feeTracker;
    }

    // ============ Synchronization ============

    function _syncFromFactory() internal virtual override {
        super._syncFromFactory();

        YieldSeekerStorageV1.Layout storage ys = YieldSeekerStorageV1.layout();

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
    function collectFees() external onlyExecutors {
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
     * @param asset Address of the asset to check (must be base asset)
     */
    function _getWithdrawableBalance(address asset) internal view returns (uint256) {
        if (asset != address(baseAsset())) revert InvalidAsset();
        uint256 balance = baseAsset().balanceOf(address(this));
        uint256 feesOwed = feeTracker().getFeesOwed(address(this));
        return balance > feesOwed ? balance - feesOwed : 0;
    }

    /**
     * @notice User withdraws any ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     * @dev Only baseAsset withdrawals are allowed to ensure fee enforcement.
     *      Non-base assets (vault shares, reward tokens) must be handled through adapters.
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external override onlyOwner {
        uint256 withdrawable = _getWithdrawableBalance(asset);
        if (withdrawable < amount) revert AWKErrors.InsufficientBalance();
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of a specific ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @dev Only baseAsset withdrawals are allowed to ensure fee enforcement.
     *      Non-base assets (vault shares, reward tokens) must be handled through adapters.
     */
    function withdrawAllAssetToUser(address recipient, address asset) external override onlyOwner {
        uint256 withdrawable = _getWithdrawableBalance(asset);
        _withdrawAsset(recipient, asset, withdrawable);
    }
}
