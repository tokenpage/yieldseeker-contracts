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

import {IAgentWallet} from "./IAgentWallet.sol";
import {IAgentWalletFactory} from "./IAgentWalletFactory.sol";
import {AWKAgentWalletV3} from "./agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {FeeActions} from "./fees/FeeActions.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "./swaps/IYieldSeekerSwapPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidAsset();
error InvalidFeeTracker();

/**
 * @title YieldSeekerStorageV1
 * @notice YieldSeeker-specific storage for base asset, fee tracking and swap rules
 * @dev Uses a different namespace than AWK to avoid collisions; V3 appends swapPolicy
 */
library YieldSeekerStorageV1 {
    /// @dev The slot is keccak256("yieldseeker.agentwallet.extensions.v1"), a plain hash rather than the ERC-7201
    ///      formula; deployed wallets use it, so it never changes
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.extensions.v1");

    struct Layout {
        IERC20 baseAsset;
        FeeTracker feeTracker;
        IYieldSeekerSwapPolicy swapPolicy;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}

/**
 * @title YieldSeekerAgentWalletV3
 * @notice YieldSeeker agent wallet with fee tracking and base asset management
 * @dev Extends AWKAgentWalletV3 with YieldSeeker-specific functionality. V3 lets the owner withdraw any token the fee
 *      tracker accounts for (the base asset, or e.g. a borrowed token), and lets every fee module collect what it is
 *      owed before funds leave.
 */
contract YieldSeekerAgentWalletV3 is AWKAgentWalletV3, IAgentWallet {
    using SafeERC20 for IERC20;

    uint256 public constant FEE_SETTLEMENT_GAS_LIMIT = 500_000;

    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker, address indexed swapPolicy);
    event FeeSettlementFailed(address indexed asset, uint256 amount);

    constructor(address factory) AWKAgentWalletV3(factory) {}

    // ============ Initializers ============

    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset, bytes32 _agentProfile) public virtual initializer {
        _initializeYieldSeeker(_owner, _ownerAgentIndex, _baseAsset, _agentProfile);
    }

    function _initializeYieldSeeker(address _owner, uint256 _ownerAgentIndex, address _baseAsset, bytes32 _agentProfile) internal onlyInitializing {
        if (_baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (_baseAsset.code.length == 0) revert AWKErrors.NotAContract(_baseAsset);

        YieldSeekerStorageV1.Layout storage ys = YieldSeekerStorageV1.layout();
        ys.baseAsset = IERC20(_baseAsset);

        // Call parent initializer
        super._initializeV3(_owner, _ownerAgentIndex, _agentProfile);
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
     * @notice Get the fee tracker (its agent profile's, copied from the factory at sync)
     * @return FeeTracker instance
     */
    function feeTracker() public view virtual returns (FeeTracker) {
        return YieldSeekerStorageV1.layout().feeTracker;
    }

    /// @notice Get the swap policy (its agent profile's, copied from the factory at sync; address(0): it can't swap)
    function swapPolicy() public view virtual returns (IYieldSeekerSwapPolicy) {
        return YieldSeekerStorageV1.layout().swapPolicy;
    }

    // ============ Synchronization ============

    function _syncFromFactory() internal virtual override {
        super._syncFromFactory();

        YieldSeekerStorageV1.Layout storage ys = YieldSeekerStorageV1.layout();
        IAgentWalletFactory factory = IAgentWalletFactory(address(FACTORY));
        bytes32 profile = agentProfile();

        FeeTracker newTracker = factory.feeTracker(profile);
        if (address(newTracker) == address(0)) revert InvalidFeeTracker();
        if (address(newTracker).code.length == 0) revert InvalidFeeTracker();
        ys.feeTracker = newTracker;
        IYieldSeekerSwapPolicy newSwapPolicy = factory.swapPolicy(profile);
        ys.swapPolicy = newSwapPolicy;

        emit SyncedFromFactory(address(adapterRegistry()), address(newTracker), address(newSwapPolicy));
    }

    // ============ YieldSeeker Withdrawal Functions (Fee-Aware) ============

    /**
     * @notice How much of `asset` the owner can withdraw now: the base asset net of fees owed, a token a fee module
     *         accounts for (e.g. a borrowed token) in full, and nothing for other tokens
     */
    function withdrawableBalance(address asset) public view returns (uint256) {
        FeeTracker tracker = feeTracker();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (asset != address(baseAsset())) return tracker.isAccountedToken(address(this), asset) ? balance : 0;
        uint256 feesOwed = tracker.feesOwedInBaseAsset(address(this));
        return balance > feesOwed ? balance - feesOwed : 0;
    }

    /**
     * @notice User withdraws exactly `amount` of an ERC20 asset from the agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw (must be accounted for by the fee tracker)
     * @param amount Amount to withdraw
     * @dev Fees owed are collected first, from the base asset; the recipient still receives exactly `amount`.
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external virtual override onlyOwner nonReentrant {
        _requireAccountedToken(asset);
        _settleFees(asset, recipient, amount);
        if (IERC20(asset).balanceOf(address(this)) < amount) revert AWKErrors.InsufficientBalance();
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of an ERC20 asset from the agent wallet, net of fees owed
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw (must be accounted for by the fee tracker)
     */
    function withdrawAllAssetToUser(address recipient, address asset) external virtual override onlyOwner nonReentrant {
        _requireAccountedToken(asset);
        _settleFees(asset, recipient, IERC20(asset).balanceOf(address(this)));
        _withdrawAsset(recipient, asset, IERC20(asset).balanceOf(address(this)));
    }

    /// @dev The base asset is always withdrawable without asking the tracker, so a broken tracker can't block its exit
    function _requireAccountedToken(address asset) internal view {
        if (asset == address(baseAsset())) return;
        if (!feeTracker().isAccountedToken(address(this), asset)) revert InvalidAsset();
    }

    /**
     * @notice Settles fees before an owner withdrawal; only callable by this wallet (see _settleFees)
     * @dev Reports the outflow (FeeActions.TRANSFER_OUT) so every fee module collects what it is owed, then pays the
     *      collector. Runs as one call so a failed payment also undoes the modules' records.
     */
    function settleFeesForWithdrawal(address asset, address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert AWKErrors.Unauthorized(msg.sender);
        bytes memory data = abi.encode(FeeActions.TransferOut({token: asset, to: recipient, amount: amount}));
        (uint256 payment, address collector) = feeTracker().reportAction(FeeActions.TRANSFER_OUT, data);
        if (payment > 0) baseAsset().safeTransfer(collector, payment);
    }

    /// @dev Gas-limited and failure-tolerant, so neither a fee module nor the fee collector can block the owner's exit;
    ///      if settlement fails, nothing is recorded, the fees stay owed and FeeSettlementFailed is emitted.
    function _settleFees(address asset, address recipient, uint256 amount) internal {
        try this.settleFeesForWithdrawal{gas: FEE_SETTLEMENT_GAS_LIMIT}(asset, recipient, amount) {}
        catch {
            emit FeeSettlementFailed(asset, amount);
        }
    }
}
