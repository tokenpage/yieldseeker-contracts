// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockFeeTracker
/// @notice Mock implementation of FeeTracker for isolated unit testing
contract MockFeeTracker is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_FEE_RATE = BASIS_POINTS; // 100%

    uint256 private _feeRate;
    address private _feeCollector;

    mapping(address => uint256) private _feesOwed;

    // Position tracking
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultCostBasis;
    mapping(address wallet => mapping(address vault => uint256)) public agentVaultShares;
    mapping(address wallet => mapping(address token => uint256)) public agentYieldTokenFeesOwed;

    event FeeConfigUpdated(uint256 indexed feeRate, address indexed collector);
    event YieldRecorded(address indexed agent, uint256 yield, uint256 feeAmount);

    constructor(uint256 feeRate, address feeCollector) {
        if (feeCollector == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }
        if (feeRate > MAX_FEE_RATE) {
            revert YieldSeekerErrors.InvalidFeeRate();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _feeRate = feeRate;
        _feeCollector = feeCollector;
    }

    function setFeeConfig(uint256 feeRate, address feeCollector) external onlyRole(ADMIN_ROLE) {
        if (feeCollector == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }
        if (feeRate > MAX_FEE_RATE) {
            revert YieldSeekerErrors.InvalidFeeRate();
        }

        _feeRate = feeRate;
        _feeCollector = feeCollector;

        emit FeeConfigUpdated(feeRate, feeCollector);
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

    function getFeeConfig() external view returns (uint256 feeRate, address feeCollector) {
        return (_feeRate, _feeCollector);
    }

    function getFeesOwed(address agent) external view returns (uint256) {
        return _feesOwed[agent];
    }

    // ============ Position Tracking ============

    function recordAgentVaultShareDeposit(address wallet, address vault, uint256 assetsDeposited, uint256 sharesReceived) external onlyRole(ADMIN_ROLE) {
        agentVaultCostBasis[wallet][vault] += assetsDeposited;
        agentVaultShares[wallet][vault] += sharesReceived;
    }

    function recordAgentVaultShareWithdraw(address wallet, address vault, uint256 sharesSpent, uint256 assetsReceived) external onlyRole(ADMIN_ROLE) {
        uint256 totalShares = agentVaultShares[wallet][vault];
        uint256 totalCostBasis = agentVaultCostBasis[wallet][vault];

        if (totalShares == 0) return;

        uint256 proportionalCost = (totalCostBasis * sharesSpent) / totalShares;

        if (assetsReceived > proportionalCost) {
            uint256 profit = assetsReceived - proportionalCost;
            uint256 fee = (profit * _feeRate) / BASIS_POINTS;
            _feesOwed[wallet] += fee;
            emit YieldRecorded(wallet, profit, fee);
        }

        agentVaultCostBasis[wallet][vault] = totalCostBasis - proportionalCost;
        agentVaultShares[wallet][vault] = totalShares - sharesSpent;
    }

    function getAgentVaultPosition(address wallet, address vault) external view returns (uint256 costBasis, uint256 shares) {
        costBasis = agentVaultCostBasis[wallet][vault];
        shares = agentVaultShares[wallet][vault];
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

    // Access control override for custom error
    function _checkRole(bytes32 role, address account) internal view override {
        if (!hasRole(role, account)) {
            revert YieldSeekerErrors.Unauthorized(account);
        }
    }
}
