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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidPlan(bytes32 feeType, uint256 planId);
error UnknownPlan(bytes32 feeType, uint256 planId);
error UnknownFeeType(bytes32 feeType);

/// @notice A wallet's choice of plan for one fee type
struct FeePlanChoice {
    bytes32 feeType;
    uint256 planId;
}

/**
 * @title YieldSeekerFeeTracker
 * @notice The fee modules (one per fee type), their plans, each wallet's plans and the fee collector
 * @dev Adapters running in a wallet report every action here (reportAction); the tracker passes it to every module,
 *      which decides what it costs, and returns what the wallet must send to the fee collector.
 *      A plan is the module's plan struct (its rates), ABI-encoded and validated by the module. Plans are numbered
 *      per fee type from 0 and never change once created; a replacement module must accept every existing plan, and
 *      can add new ones. The wallet factory sets a wallet's plans when it creates the wallet, and they never change
 *      either: moving to another plan means moving to a new wallet. Fee types without a plan for a wallet use plan 0.
 *      The admin (timelock) sets modules, creates plans and sets the wallet factory and the fee collector.
 *      Replacing a module drops the fee state the old one holds for wallets unless the new one imports it.
 */
contract YieldSeekerFeeTracker is AccessControl {
    uint256 public constant MODULE_GAS_LIMIT = 200_000;

    address public feeCollector;
    address public walletFactory;
    bytes32[] internal _moduleFeeTypes;
    IYieldSeekerFeeModule[] internal _modules;
    mapping(bytes32 feeType => IYieldSeekerFeeModule) public feeModules;
    mapping(bytes32 feeType => bytes[] plan) internal _plans;
    mapping(address wallet => mapping(bytes32 feeType => uint256 planId)) public walletPlanId;

    event FeeCollectorUpdated(address feeCollector);
    event WalletFactoryUpdated(address walletFactory);
    event FeeModuleSet(bytes32 indexed feeType, address indexed module);
    event PlanCreated(bytes32 indexed feeType, uint256 indexed planId, bytes plan);
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

    /// @notice The factory allowed to set new wallets' plans (initWalletPlans)
    function setWalletFactory(address newWalletFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWalletFactory.code.length == 0) revert AWKErrors.NotAContract(newWalletFactory);
        walletFactory = newWalletFactory;
        emit WalletFactoryUpdated(newWalletFactory);
    }

    /// @notice Plug in or replace a fee type's module; a replacement must accept every existing plan of the fee type
    function setFeeModule(bytes32 feeType, IYieldSeekerFeeModule module) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(module).code.length == 0) revert AWKErrors.NotAContract(address(module));
        bytes[] storage plans = _plans[feeType];
        for (uint256 i = 0; i < plans.length; i++) {
            if (!module.isValidPlan(plans[i])) revert InvalidPlan(feeType, i);
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

    /**
     * @notice Report an action of the calling wallet (FeeActions) to every module, in the order they were added
     * @dev Called by adapters running in the wallet, so msg.sender is the wallet; a caller only affects its own
     *      accounting. Each module pays from the wallet's base asset that the modules before it left.
     * @return payment Base asset the wallet must now send to the fee collector (already recorded as paid)
     * @return collector The fee collector
     */
    function reportAction(bytes32 action, bytes calldata data) external returns (uint256 payment, address collector) {
        uint256 available = IERC20(IAgentWallet(msg.sender).baseAsset()).balanceOf(msg.sender);
        for (uint256 i = 0; i < _modules.length; i++) {
            payment += _modules[i].onAction(msg.sender, action, data, available - payment);
        }
        return (payment, feeCollector);
    }

    /// @notice Add a plan (the module's plan struct, ABI-encoded); plan 0 applies to every wallet not given another
    function createPlan(bytes32 feeType, bytes calldata newPlan) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 planId) {
        IYieldSeekerFeeModule module = feeModules[feeType];
        if (address(module) == address(0)) revert UnknownFeeType(feeType);
        planId = _plans[feeType].length;
        if (!module.isValidPlan(newPlan)) revert InvalidPlan(feeType, planId);
        _plans[feeType].push(newPlan);
        emit PlanCreated(feeType, planId, newPlan);
    }

    function planCount(bytes32 feeType) external view returns (uint256) {
        return _plans[feeType].length;
    }

    function plan(bytes32 feeType, uint256 planId) external view returns (bytes memory) {
        if (planId >= _plans[feeType].length) revert UnknownPlan(feeType, planId);
        return _plans[feeType][planId];
    }

    /// @notice Set a new wallet's plans; only the wallet factory calls this, once, when it creates the wallet
    function initWalletPlans(address wallet, FeePlanChoice[] calldata choices) external {
        if (msg.sender != walletFactory) revert AWKErrors.Unauthorized(msg.sender);
        for (uint256 i = 0; i < choices.length; i++) {
            FeePlanChoice calldata choice = choices[i];
            if (choice.planId >= _plans[choice.feeType].length) revert UnknownPlan(choice.feeType, choice.planId);
            walletPlanId[wallet][choice.feeType] = choice.planId;
            emit WalletPlanSet(wallet, choice.feeType, choice.planId);
        }
    }

    /// @notice A wallet's plan for a fee type (the module's plan struct, ABI-encoded); empty until the type has plans
    function walletPlan(address wallet, bytes32 feeType) external view returns (bytes memory) {
        bytes[] storage plans = _plans[feeType];
        uint256 planId = walletPlanId[wallet][feeType];
        return planId < plans.length ? plans[planId] : bytes("");
    }

    /**
     * @notice Whether `wallet` may hold and send `token`: its base asset, or a token a module accounts for
     * @dev Each module is called with a gas limit and a module that fails counts as false.
     */
    function isAccountedToken(address wallet, address token) external view returns (bool) {
        if (token == address(IAgentWallet(wallet).baseAsset())) return true;
        for (uint256 i = 0; i < _modules.length; i++) {
            try _modules[i].isAccountedToken{gas: MODULE_GAS_LIMIT}(wallet, token) returns (bool accounted) {
                if (accounted) return true;
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
