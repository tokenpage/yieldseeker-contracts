// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidAsset} from "../../src/AgentWalletV1.sol";
import {IAgentWallet} from "../../src/IAgentWallet.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {InvalidFeeRate} from "../../src/fees/FeePlans.sol";
import {IYieldSeekerFeeModule, IYieldSeekerFeeModuleHost} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title MockFeeTracker
/// @notice Mock implementation of FeeTracker for isolated unit testing
contract MockFeeTracker is AccessControl, IYieldSeekerFeeModuleHost {
    using SafeCast for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_FEE_RATE = BASIS_POINTS; // 100%

    mapping(bytes32 feeType => IYieldSeekerFeeModule module) public override feeModules;
    mapping(address => uint256) private _feesPaid;
    uint256 private _feeRate;
    address private _feeCollector;

    mapping(address => uint256) private _feesOwed;

    struct VaultPosition {
        uint128 costBasis;
        uint128 shares;
    }

    // Position tracking
    mapping(address wallet => mapping(address vault => VaultPosition)) internal _agentVaultPositions;
    mapping(address wallet => mapping(address token => uint256)) public agentYieldTokenFeesOwed;

    event FeeConfigUpdated(uint256 indexed feeRate, address indexed collector);
    event YieldRecorded(address indexed agent, uint256 yield, uint256 feeAmount);

    constructor(uint256 feeRate, address initialFeeCollector) {
        if (initialFeeCollector == address(0)) {
            revert AWKErrors.ZeroAddress();
        }
        if (feeRate > MAX_FEE_RATE) {
            revert InvalidFeeRate();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _feeRate = feeRate;
        _feeCollector = initialFeeCollector;
    }

    function setFeeConfig(uint256 feeRate, address newFeeCollector) external onlyRole(ADMIN_ROLE) {
        if (newFeeCollector == address(0)) {
            revert AWKErrors.ZeroAddress();
        }
        if (feeRate > MAX_FEE_RATE) {
            revert InvalidFeeRate();
        }

        _feeRate = feeRate;
        _feeCollector = newFeeCollector;

        emit FeeConfigUpdated(feeRate, newFeeCollector);
    }

    function recordYield(address agent, uint256 yieldAmount) external onlyRole(ADMIN_ROLE) {
        if (yieldAmount == 0) return;

        uint256 feeAmount = calculateFeeAmount(yieldAmount);
        _feesOwed[agent] += feeAmount;

        emit YieldRecorded(agent, yieldAmount, feeAmount);
    }

    function calculateFeeAmount(uint256 yieldAmount) public view returns (uint256) {
        return (yieldAmount * _feeRate) / BASIS_POINTS;
    }

    function getFeeConfig() external view returns (uint256 feeRate, address collectorAddress) {
        return (_feeRate, _feeCollector);
    }

    function feeCollector() external view returns (address) {
        return _feeCollector;
    }

    function recordFeePaid(uint256 amount) external {
        _feesPaid[msg.sender] += amount;
    }

    function getFeesOwed(address agent) public view returns (uint256) {
        uint256 owed = _feesOwed[agent];
        uint256 paid = _feesPaid[agent];
        return owed > paid ? owed - paid : 0;
    }

    function feesReserved(address wallet, address token) external view override returns (uint256) {
        if (token != address(IAgentWallet(wallet).baseAsset())) revert InvalidAsset();
        return getFeesOwed(wallet);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IYieldSeekerFeeModuleHost).interfaceId || super.supportsInterface(interfaceId);
    }

    // ============ Position Tracking ============

    function recordAgentVaultShareDeposit(address wallet, address vault, uint256 assetsDeposited, uint256 sharesReceived) external onlyRole(ADMIN_ROLE) {
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        pos.costBasis = (uint256(pos.costBasis) + assetsDeposited).toUint128();
        pos.shares = (uint256(pos.shares) + sharesReceived).toUint128();
    }

    function recordAgentVaultShareWithdraw(address wallet, address vault, uint256 sharesSpent, uint256 assetsReceived) external onlyRole(ADMIN_ROLE) {
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        uint256 totalShares = pos.shares;
        uint256 totalCostBasis = pos.costBasis;
        if (totalShares == 0) return;
        uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;
        if (assetsReceived > proportionalCost) {
            uint256 profit = assetsReceived - proportionalCost;
            uint256 fee = (profit * _feeRate) / BASIS_POINTS;
            _feesOwed[wallet] += fee;
            emit YieldRecorded(wallet, profit, fee);
        }
        pos.costBasis = (totalCostBasis - proportionalCost).toUint128();
        pos.shares = (totalShares - sharesSpent).toUint128();
    }

    function getAgentVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        VaultPosition storage pos = _agentVaultPositions[wallet][vault];
        costBasis = pos.costBasis;
        shares = pos.shares;
    }

    function agentVaultCostBasis(address wallet, address vault) external view returns (uint256) {
        return _agentVaultPositions[wallet][vault].costBasis;
    }

    function agentVaultShares(address wallet, address vault) external view returns (uint256) {
        return _agentVaultPositions[wallet][vault].shares;
    }

    function recordAgentYieldTokenEarned(address wallet, address token, uint256 amount) external onlyRole(ADMIN_ROLE) {
        uint256 feeInToken = (amount * _feeRate) / BASIS_POINTS;
        agentYieldTokenFeesOwed[wallet][token] += feeInToken;
    }

    function recordAgentTokenSwap(address wallet, address token, uint256 swappedAmount, uint256 baseAssetReceived) external onlyRole(ADMIN_ROLE) {
        // Guard against division by zero - can happen with broken/paused tokens
        if (swappedAmount == 0) return;

        uint256 feeTokenOwed = agentYieldTokenFeesOwed[wallet][token];

        if (feeTokenOwed > 0) {
            uint256 feeTokenSwapped = swappedAmount > feeTokenOwed ? feeTokenOwed : swappedAmount;
            agentYieldTokenFeesOwed[wallet][token] = feeTokenOwed - feeTokenSwapped;

            uint256 feeInBaseAsset = (baseAssetReceived * feeTokenSwapped) / swappedAmount;
            _feesOwed[wallet] += feeInBaseAsset;
            emit YieldRecorded(wallet, feeInBaseAsset, feeInBaseAsset);
        }
    }

    function getAgentYieldTokenFeesOwed(address wallet, address token) external view returns (uint256) {
        return agentYieldTokenFeesOwed[wallet][token];
    }

    // ============ Test Helpers ============

    /// @dev Test helper to set fees owed directly
    function setFeesOwed(address agent, uint256 amount) external {
        _feesOwed[agent] = amount;
    }

    // Access control override for custom error
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) {
            revert AWKErrors.Unauthorized(account);
        }
    }
}
