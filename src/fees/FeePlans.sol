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

import {AWKAgentWalletV3} from "../agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModule, IYieldSeekerFeeModuleHost} from "./IYieldSeekerFeeModule.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error InvalidFeeRate();
error UnknownPlan(uint256 planId);
error PlanRateIncrease(bytes32 feeType, uint256 currentRateBps, uint256 newRateBps);
error UnknownFeeType(bytes32 feeType);
error FeeModuleAlreadySet(bytes32 feeType);

/**
 * @title YieldSeekerFeePlans
 * @notice Fee plans per user (wallet owner) and the fee modules plugged into a fee tracker
 * @dev Every owner starts on plan 0. A plan has a rate per fee type: VAULT_FEE (the tracker's own vault accounting)
 *      and one per module. The admin (timelock) sets plan rates, the fee collector, adds modules and can assign any
 *      plan. The plan manager can only move an owner to a plan that is not more expensive for any fee type.
 *      Modules can be added but never replaced or removed, so fees they hold for wallets cannot be dropped.
 *      No rate can exceed its fee type's MAX_FEE_RATE_BPS, which is fixed at deployment.
 */
abstract contract YieldSeekerFeePlans is AccessControl, IYieldSeekerFeeModuleHost {
    bytes32 public constant PLAN_MANAGER_ROLE = keccak256("PLAN_MANAGER_ROLE");
    bytes32 public constant VAULT_FEE = keccak256("vault");

    uint256 public immutable MAX_FEE_RATE_BPS;

    address public feeCollector;
    bytes32[] internal _moduleFeeTypes;
    mapping(bytes32 feeType => IYieldSeekerFeeModule) public feeModules;
    mapping(uint256 planId => mapping(bytes32 feeType => uint256 rateBps)) public planRateBps;
    mapping(uint256 planId => bool exists) public planExists;
    mapping(address owner => uint256 planId) public planOf;

    event FeeCollectorUpdated(address feeCollector);
    event FeeModuleAdded(bytes32 indexed feeType, address indexed module);
    event PlanRateUpdated(uint256 indexed planId, bytes32 indexed feeType, uint256 rateBps);
    event PlanAssigned(address indexed owner, uint256 indexed planId);

    constructor(address admin, address planManager, address initialFeeCollector, uint256 maxVaultFeeRateBps, uint256 defaultRateBps) {
        if (admin == address(0) || planManager == address(0) || initialFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        if (maxVaultFeeRateBps > 1e4) revert InvalidFeeRate();
        MAX_FEE_RATE_BPS = maxVaultFeeRateBps;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLAN_MANAGER_ROLE, planManager);
        feeCollector = initialFeeCollector;
        _setPlanRate(0, VAULT_FEE, defaultRateBps);
    }

    function setFeeCollector(address newFeeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    /// @notice Plug in a fee type; set its plan rates with setPlanRate (unset rates are 0)
    function addFeeModule(bytes32 feeType, IYieldSeekerFeeModule module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(module).code.length == 0) revert AWKErrors.NotAContract(address(module));
        if (feeType == VAULT_FEE || address(feeModules[feeType]) != address(0)) revert FeeModuleAlreadySet(feeType);
        feeModules[feeType] = module;
        _moduleFeeTypes.push(feeType);
        emit FeeModuleAdded(feeType, address(module));
    }

    function moduleFeeTypes() external view returns (bytes32[] memory) {
        return _moduleFeeTypes;
    }

    function setPlanRate(uint256 planId, bytes32 feeType, uint256 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPlanRate(planId, feeType, rateBps);
    }

    function _setPlanRate(uint256 planId, bytes32 feeType, uint256 rateBps) internal {
        if (rateBps > maxFeeRateBps(feeType)) revert InvalidFeeRate();
        planRateBps[planId][feeType] = rateBps;
        planExists[planId] = true;
        emit PlanRateUpdated(planId, feeType, rateBps);
    }

    function maxFeeRateBps(bytes32 feeType) public view returns (uint256) {
        if (feeType == VAULT_FEE) return MAX_FEE_RATE_BPS;
        IYieldSeekerFeeModule module = feeModules[feeType];
        if (address(module) == address(0)) revert UnknownFeeType(feeType);
        return module.MAX_FEE_RATE_BPS();
    }

    function assignPlan(address owner, uint256 planId) external {
        if (!planExists[planId]) revert UnknownPlan(planId);
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            if (!hasRole(PLAN_MANAGER_ROLE, msg.sender)) revert AWKErrors.Unauthorized(msg.sender);
            uint256 currentPlanId = planOf[owner];
            _requireNotMoreExpensive(currentPlanId, planId, VAULT_FEE);
            for (uint256 i = 0; i < _moduleFeeTypes.length; i++) {
                _requireNotMoreExpensive(currentPlanId, planId, _moduleFeeTypes[i]);
            }
        }
        planOf[owner] = planId;
        emit PlanAssigned(owner, planId);
    }

    function _requireNotMoreExpensive(uint256 currentPlanId, uint256 newPlanId, bytes32 feeType) internal view {
        uint256 currentRateBps = planRateBps[currentPlanId][feeType];
        uint256 newRateBps = planRateBps[newPlanId][feeType];
        if (newRateBps > currentRateBps) revert PlanRateIncrease(feeType, currentRateBps, newRateBps);
    }

    /// @notice The rate of a fee type for a wallet, from its owner's plan
    function feeRateBps(bytes32 feeType, address wallet) public view returns (uint256) {
        return planRateBps[planOf[AWKAgentWalletV3(payable(wallet)).owner()]][feeType];
    }

    /// @notice The vault fee rate for a wallet, from its owner's plan
    function feeRateBpsForWallet(address wallet) public view returns (uint256) {
        return feeRateBps(VAULT_FEE, wallet);
    }

    /// @dev The factory only accepts trackers that report IYieldSeekerFeeModuleHost, since V3 wallets pin them for good
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IYieldSeekerFeeModuleHost).interfaceId || super.supportsInterface(interfaceId);
    }
}
