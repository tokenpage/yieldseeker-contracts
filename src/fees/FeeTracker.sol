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

import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKAgentWalletV3} from "../agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error InvalidFeeRate();
error UnknownPlan(uint256 planId);
error PlanRateIncrease(bytes32 feeType, uint256 currentRateBps, uint256 newRateBps);
error UnknownFeeType(bytes32 feeType);

/**
 * @title YieldSeekerFeeTracker
 * @notice Fee plans per user (wallet owner), the fee collector and the fee modules that do each fee type's accounting
 * @dev Every fee type is a module (e.g. the vault fee, the borrow fee) that wallets and their adapters call directly.
 *      Every owner starts on plan 0. A plan has a rate per fee type. The admin (timelock) sets plan rates and the fee
 *      collector, sets modules and can assign any plan. The plan manager can only move an owner to a plan that is not
 *      more expensive for any fee type.
 *      Replacing a module drops the fee state the old one holds for wallets unless it is migrated first.
 *      No rate can exceed its module's MAX_FEE_RATE_BPS, which is fixed at deployment.
 */
contract YieldSeekerFeeTracker is AccessControl {
    bytes32 public constant PLAN_MANAGER_ROLE = keccak256("PLAN_MANAGER_ROLE");
    uint256 public constant MODULE_GAS_LIMIT = 200_000;

    address public feeCollector;
    bytes32[] internal _moduleFeeTypes;
    mapping(bytes32 feeType => IYieldSeekerFeeModule) public feeModules;
    mapping(uint256 planId => mapping(bytes32 feeType => uint256 rateBps)) public planRateBps;
    mapping(uint256 planId => bool exists) public planExists;
    mapping(address owner => uint256 planId) public planOf;

    event FeeCollectorUpdated(address feeCollector);
    event FeeModuleSet(bytes32 indexed feeType, address indexed module);
    event PlanRateUpdated(uint256 indexed planId, bytes32 indexed feeType, uint256 rateBps);
    event PlanAssigned(address indexed owner, uint256 indexed planId);

    constructor(address admin, address planManager, address initialFeeCollector) {
        if (admin == address(0) || planManager == address(0) || initialFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLAN_MANAGER_ROLE, planManager);
        feeCollector = initialFeeCollector;
        planExists[0] = true;
    }

    function setFeeCollector(address newFeeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    /// @notice Plug in or replace a fee type's module; set a new fee type's plan rates with setPlanRate (unset rates are 0)
    function setFeeModule(bytes32 feeType, IYieldSeekerFeeModule module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(module).code.length == 0) revert AWKErrors.NotAContract(address(module));
        if (address(feeModules[feeType]) == address(0)) _moduleFeeTypes.push(feeType);
        feeModules[feeType] = module;
        emit FeeModuleSet(feeType, address(module));
    }

    function moduleFeeTypes() external view returns (bytes32[] memory) {
        return _moduleFeeTypes;
    }

    function setPlanRate(uint256 planId, bytes32 feeType, uint256 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (rateBps > maxFeeRateBps(feeType)) revert InvalidFeeRate();
        planRateBps[planId][feeType] = rateBps;
        planExists[planId] = true;
        emit PlanRateUpdated(planId, feeType, rateBps);
    }

    function maxFeeRateBps(bytes32 feeType) public view returns (uint256) {
        IYieldSeekerFeeModule module = feeModules[feeType];
        if (address(module) == address(0)) revert UnknownFeeType(feeType);
        return module.MAX_FEE_RATE_BPS();
    }

    function assignPlan(address owner, uint256 planId) external {
        if (!planExists[planId]) revert UnknownPlan(planId);
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            if (!hasRole(PLAN_MANAGER_ROLE, msg.sender)) revert AWKErrors.Unauthorized(msg.sender);
            uint256 currentPlanId = planOf[owner];
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

    /**
     * @notice Whether `token` may leave `wallet`, and how much of it the wallet must keep for fees owed
     * @dev The base asset may always leave; other tokens only if a module accounts for them. Each module is called
     *      with a gas limit and a module that fails counts as (false, 0), so no module can block a wallet's exits.
     */
    function withdrawReserve(address wallet, address token) external view returns (bool allowed, uint256 reserved) {
        allowed = token == address(IAgentWallet(wallet).baseAsset());
        for (uint256 i = 0; i < _moduleFeeTypes.length; i++) {
            try feeModules[_moduleFeeTypes[i]].withdrawReserve{gas: MODULE_GAS_LIMIT}(wallet, token) returns (bool moduleAllows, uint256 moduleReserved) {
                allowed = allowed || moduleAllows;
                reserved += moduleReserved;
            } catch {}
        }
    }
}
