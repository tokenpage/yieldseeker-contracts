// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title FeeLedgerStorage
 * @notice Storage layout for FeeLedger using ERC-7201 namespaced storage pattern
 */
library FeeLedgerStorage {
    /// @custom:storage-location erc7201:yieldseeker.feeledger.storage.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.feeledger.storage.v1");

    struct Layout {
        uint256 feeRateBps;
        address feeCollector;
        mapping(address wallet => mapping(address vault => uint256)) vaultCostBasis;
        mapping(address wallet => mapping(address vault => uint256)) vaultShares;
        mapping(address wallet => uint256) realizedYield;
        mapping(address wallet => uint256) feesPaid;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}

/**
 * @title YieldSeekerFeeLedger
 * @notice Tracks yield and fees for YieldSeeker wallets
 * @dev Called by adapters (via delegatecall from wallets) to record deposits, withdrawals, and rewards.
 *      All recording functions use msg.sender, so callers can only affect their own accounting.
 *      Uses UUPS proxy pattern for upgradeability.
 */
contract YieldSeekerFeeLedger is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using FeeLedgerStorage for FeeLedgerStorage.Layout;

    event DepositRecorded(address indexed wallet, address indexed vault, uint256 amount, uint256 shares);
    event WithdrawRecorded(address indexed wallet, address indexed vault, uint256 shares, uint256 received, uint256 yield);
    event RewardClaimed(address indexed wallet, uint256 amount);
    event FeePaid(address indexed wallet, uint256 amount);
    event FeeConfigUpdated(uint256 feeRateBps, address feeCollector);

    error InvalidShares();
    error ZeroAddress();
    error InvalidFeeRate();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function feeRateBps() external view returns (uint256) {
        return FeeLedgerStorage.layout().feeRateBps;
    }

    function feeCollector() external view returns (address) {
        return FeeLedgerStorage.layout().feeCollector;
    }

    function vaultCostBasis(address wallet, address vault) external view returns (uint256) {
        return FeeLedgerStorage.layout().vaultCostBasis[wallet][vault];
    }

    function vaultShares(address wallet, address vault) external view returns (uint256) {
        return FeeLedgerStorage.layout().vaultShares[wallet][vault];
    }

    function realizedYield(address wallet) external view returns (uint256) {
        return FeeLedgerStorage.layout().realizedYield[wallet];
    }

    function feesPaid(address wallet) external view returns (uint256) {
        return FeeLedgerStorage.layout().feesPaid[wallet];
    }

    function setFeeConfig(uint256 _feeRateBps, address _feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feeRateBps > 5000) revert InvalidFeeRate();
        if (_feeCollector == address(0)) revert ZeroAddress();
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        $.feeRateBps = _feeRateBps;
        $.feeCollector = _feeCollector;
        emit FeeConfigUpdated(_feeRateBps, _feeCollector);
    }

    function recordVaultShareDeposit(address vault, uint256 assetAmount, uint256 sharesReceived) external {
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        $.vaultCostBasis[msg.sender][vault] += assetAmount;
        $.vaultShares[msg.sender][vault] += sharesReceived;
        emit DepositRecorded(msg.sender, vault, assetAmount, sharesReceived);
    }

    function recordVaultShareWithdraw(address vault, uint256 sharesSpent, uint256 assetReceived) external {
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        uint256 totalShares = $.vaultShares[msg.sender][vault];
        uint256 totalCostBasis = $.vaultCostBasis[msg.sender][vault];
        if (totalShares == 0 || sharesSpent > totalShares) revert InvalidShares();
        uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
        uint256 yieldEarned = 0;
        if (assetReceived > proportionalCost) {
            yieldEarned = assetReceived - proportionalCost;
            $.realizedYield[msg.sender] += yieldEarned;
        }
        $.vaultCostBasis[msg.sender][vault] = totalCostBasis - proportionalCost;
        $.vaultShares[msg.sender][vault] = totalShares - sharesSpent;
        emit WithdrawRecorded(msg.sender, vault, sharesSpent, assetReceived, yieldEarned);
    }

    function recordRewardClaim(uint256 amount) external {
        FeeLedgerStorage.layout().realizedYield[msg.sender] += amount;
        emit RewardClaimed(msg.sender, amount);
    }

    function recordFeePaid(uint256 amount) external {
        FeeLedgerStorage.layout().feesPaid[msg.sender] += amount;
        emit FeePaid(msg.sender, amount);
    }

    function getFeesOwed(address wallet) external view returns (uint256) {
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        uint256 totalFeesDue = ($.realizedYield[wallet] * $.feeRateBps) / 10000;
        return totalFeesDue > $.feesPaid[wallet] ? totalFeesDue - $.feesPaid[wallet] : 0;
    }

    function getWalletStats(address wallet) external view returns (uint256 totalRealizedYield, uint256 totalFeesPaid, uint256 feesOwed) {
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        totalRealizedYield = $.realizedYield[wallet];
        totalFeesPaid = $.feesPaid[wallet];
        feesOwed = this.getFeesOwed(wallet);
    }

    function getVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        FeeLedgerStorage.Layout storage $ = FeeLedgerStorage.layout();
        costBasis = $.vaultCostBasis[wallet][vault];
        shares = $.vaultShares[wallet][vault];
    }
}
