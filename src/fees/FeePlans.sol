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

import {AWKAgentWalletV2} from "../agentwalletkit/AWKAgentWalletV2.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error InvalidFeeRate();
error UnknownPlan(uint256 planId);
error PlanRateIncrease(uint256 currentRateBps, uint256 newRateBps);

/**
 * @title YieldSeekerFeePlans
 * @notice Fee rate per user (wallet owner) for a fee contract
 * @dev Every owner starts on plan 0. The admin (timelock) sets plan rates, the fee collector, and can assign
 *      any plan. The plan manager can only move an owner to a plan with an equal or lower rate.
 *      No rate can exceed MAX_FEE_RATE_BPS, which is fixed at deployment.
 */
abstract contract YieldSeekerFeePlans is AccessControl, IYieldSeekerFeeModule {
    bytes32 public constant PLAN_MANAGER_ROLE = keccak256("PLAN_MANAGER_ROLE");

    uint256 public immutable MAX_FEE_RATE_BPS;

    address public feeCollector;
    mapping(uint256 planId => uint256 rateBps) public planRateBps;
    mapping(uint256 planId => bool exists) public planExists;
    mapping(address owner => uint256 planId) public planOf;

    event FeeCollectorUpdated(address feeCollector);
    event PlanRateUpdated(uint256 indexed planId, uint256 rateBps);
    event PlanAssigned(address indexed owner, uint256 indexed planId);

    constructor(address admin, address planManager, address initialFeeCollector, uint256 maxFeeRateBps, uint256 defaultRateBps) {
        if (admin == address(0) || planManager == address(0) || initialFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        if (maxFeeRateBps > 1e4) revert InvalidFeeRate();
        MAX_FEE_RATE_BPS = maxFeeRateBps;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLAN_MANAGER_ROLE, planManager);
        feeCollector = initialFeeCollector;
        _setPlanRate(0, defaultRateBps);
    }

    function setFeeCollector(address newFeeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    function setPlanRate(uint256 planId, uint256 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPlanRate(planId, rateBps);
    }

    function _setPlanRate(uint256 planId, uint256 rateBps) internal {
        if (rateBps > MAX_FEE_RATE_BPS) revert InvalidFeeRate();
        planRateBps[planId] = rateBps;
        planExists[planId] = true;
        emit PlanRateUpdated(planId, rateBps);
    }

    function assignPlan(address owner, uint256 planId) external {
        if (!planExists[planId]) revert UnknownPlan(planId);
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            if (!hasRole(PLAN_MANAGER_ROLE, msg.sender)) revert AWKErrors.Unauthorized(msg.sender);
            uint256 currentRateBps = planRateBps[planOf[owner]];
            if (planRateBps[planId] > currentRateBps) revert PlanRateIncrease(currentRateBps, planRateBps[planId]);
        }
        planOf[owner] = planId;
        emit PlanAssigned(owner, planId);
    }

    /// @notice The rate for a wallet, from its owner's plan
    function feeRateBpsForWallet(address wallet) public view returns (uint256) {
        return planRateBps[planOf[AWKAgentWalletV2(payable(wallet)).owner()]];
    }

    /// @dev The factory only accepts fee contracts that report IYieldSeekerFeeModule, since V3 wallets pin them for good
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IYieldSeekerFeeModule).interfaceId || super.supportsInterface(interfaceId);
    }
}
