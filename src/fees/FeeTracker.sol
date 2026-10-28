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
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModule} from "./IYieldSeekerFeeModule.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

error InvalidFeeRate();
error UnknownPlan(bytes32 feeType, uint256 planId);
error UnknownFeeType(bytes32 feeType);

/// @notice A wallet's plan for one fee type
struct FeePlan {
    bytes32 feeType;
    uint256 planId;
}

/**
 * @title YieldSeekerFeeTracker
 * @notice The fee modules (one per fee type), their plans, each wallet's plans and the fee collector
 * @dev Every fee type is a module (e.g. the yield fee, the borrow fee) that adapters report every wallet action to.
 *      A plan is a rate for one fee type; plans are numbered per fee type from 0 and never change once created.
 *      The wallet factory sets a wallet's plans when it creates the wallet, and they never change either: moving to
 *      another plan means moving to a new wallet. Fee types without a plan for a wallet use plan 0.
 *      The admin (timelock) sets modules, creates plans and sets the fee collector.
 *      Replacing a module drops the fee state the old one holds for wallets unless it is migrated first.
 *      No plan rate can exceed its module's MAX_FEE_RATE_BPS, which is fixed at deployment.
 */
contract YieldSeekerFeeTracker is AccessControl {
    bytes32 public constant WALLET_FACTORY_ROLE = keccak256("WALLET_FACTORY_ROLE");
    uint256 public constant MODULE_GAS_LIMIT = 200_000;

    address public feeCollector;
    bytes32[] internal _moduleFeeTypes;
    IYieldSeekerFeeModule[] internal _modules;
    mapping(bytes32 feeType => IYieldSeekerFeeModule) public feeModules;
    mapping(bytes32 feeType => uint256[] rateBps) internal _planRates;
    mapping(address wallet => mapping(bytes32 feeType => uint256 planId)) public walletPlan;

    event FeeCollectorUpdated(address feeCollector);
    event FeeModuleSet(bytes32 indexed feeType, address indexed module);
    event PlanCreated(bytes32 indexed feeType, uint256 indexed planId, uint256 rateBps);
    event WalletPlanSet(address indexed wallet, bytes32 indexed feeType, uint256 indexed planId);

    constructor(address admin, address initialFeeCollector) {
        if (admin == address(0) || initialFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        feeCollector = initialFeeCollector;
    }

    function setFeeCollector(address newFeeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeCollector == address(0)) revert AWKErrors.ZeroAddress();
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(newFeeCollector);
    }

    /// @notice Plug in or replace a fee type's module; a replacement must allow every existing plan's rate
    function setFeeModule(bytes32 feeType, IYieldSeekerFeeModule module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(module).code.length == 0) revert AWKErrors.NotAContract(address(module));
        uint256[] storage rates = _planRates[feeType];
        uint256 maxRateBps = module.MAX_FEE_RATE_BPS();
        for (uint256 i = 0; i < rates.length; i++) {
            if (rates[i] > maxRateBps) revert InvalidFeeRate();
        }
        if (address(feeModules[feeType]) == address(0)) {
            _moduleFeeTypes.push(feeType);
            _modules.push(module);
        } else {
            for (uint256 i = 0; i < _moduleFeeTypes.length; i++) {
                if (_moduleFeeTypes[i] == feeType) _modules[i] = module;
            }
        }
        feeModules[feeType] = module;
        emit FeeModuleSet(feeType, address(module));
    }

    function moduleFeeTypes() external view returns (bytes32[] memory) {
        return _moduleFeeTypes;
    }

    /// @notice Everything an adapter needs to settle fees after an action, in one call
    function feeModulesAndCollector() external view returns (IYieldSeekerFeeModule[] memory modules, address collector) {
        return (_modules, feeCollector);
    }

    /// @notice Add a plan for a fee type; the first one (plan 0) applies to every wallet not given another
    function createPlan(bytes32 feeType, uint256 rateBps) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 planId) {
        IYieldSeekerFeeModule module = feeModules[feeType];
        if (address(module) == address(0)) revert UnknownFeeType(feeType);
        if (rateBps > module.MAX_FEE_RATE_BPS()) revert InvalidFeeRate();
        planId = _planRates[feeType].length;
        _planRates[feeType].push(rateBps);
        emit PlanCreated(feeType, planId, rateBps);
    }

    function planCount(bytes32 feeType) external view returns (uint256) {
        return _planRates[feeType].length;
    }

    function planRateBps(bytes32 feeType, uint256 planId) external view returns (uint256) {
        if (planId >= _planRates[feeType].length) revert UnknownPlan(feeType, planId);
        return _planRates[feeType][planId];
    }

    /// @notice Set a new wallet's plans; only the wallet factory calls this, once, when it creates the wallet
    function setWalletPlans(address wallet, FeePlan[] calldata plans) external onlyRole(WALLET_FACTORY_ROLE) {
        for (uint256 i = 0; i < plans.length; i++) {
            FeePlan calldata plan = plans[i];
            if (plan.planId >= _planRates[plan.feeType].length) revert UnknownPlan(plan.feeType, plan.planId);
            walletPlan[wallet][plan.feeType] = plan.planId;
            emit WalletPlanSet(wallet, plan.feeType, plan.planId);
        }
    }

    /// @notice The rate of a fee type for a wallet, from its plan (0 until the fee type has a plan)
    function feeRateBps(bytes32 feeType, address wallet) external view returns (uint256) {
        uint256[] storage rates = _planRates[feeType];
        uint256 planId = walletPlan[wallet][feeType];
        return planId < rates.length ? rates[planId] : 0;
    }

    /**
     * @notice Whether `wallet` may hold and send `token`: its base asset, or a token a module accounts for
     * @dev Each module is called with a gas limit and a module that fails counts as false.
     */
    function tracksToken(address wallet, address token) external view returns (bool) {
        if (token == address(IAgentWallet(wallet).baseAsset())) return true;
        for (uint256 i = 0; i < _modules.length; i++) {
            try _modules[i].tracksToken{gas: MODULE_GAS_LIMIT}(wallet, token) returns (bool tracked) {
                if (tracked) return true;
            } catch {}
        }
        return false;
    }

    /**
     * @notice How much `token` `wallet` must keep for fees owed, across every module
     * @dev Each module is called with a gas limit and a module that fails counts as 0, so no module can block exits.
     */
    function feesHeld(address wallet, address token) external view returns (uint256 held) {
        for (uint256 i = 0; i < _modules.length; i++) {
            try _modules[i].feesHeld{gas: MODULE_GAS_LIMIT}(wallet, token) returns (uint256 moduleHeld) {
                held += moduleHeld;
            } catch {}
        }
    }
}
