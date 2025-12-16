// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAdminTimelock} from "../src/YieldSeekerAdminTimelock.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";

/// @title DeployYieldSeeker
/// @notice Deploys the full YieldSeeker smart wallet infrastructure
/// @dev Run with: forge script script/Deploy.s.sol:DeployYieldSeeker --rpc-url <RPC> --broadcast
///
/// Required environment variables:
///   DEPLOYER_PRIVATE_KEY    - Private key for deployment transactions
///   PROPOSER_ADDRESS        - Multisig that can schedule timelock operations
///   EXECUTOR_ADDRESS        - Multisig that can execute timelock operations
///
/// After deployment, run ScheduleTimelockOperations with additional env vars,
/// then wait 24h and run ExecuteTimelockOperations.
contract DeployYieldSeeker is Script {
    YieldSeekerAdminTimelock public timelock;
    YieldSeekerAgentWallet public walletImplementation;
    YieldSeekerAgentWalletFactory public factory;
    ActionRegistry public registry;
    AgentActionRouter public router;
    ERC4626Adapter public erc4626Adapter;
    AaveV3Adapter public aaveV3Adapter;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proposer = vm.envAddress("PROPOSER_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");
        vm.startBroadcast(deployerKey);
        console.log("=== Phase 1: Deploying Timelock ===");
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new YieldSeekerAdminTimelock(1 hours, proposers, executors, address(0));
        console.log("YieldSeekerAdminTimelock:", address(timelock));
        console.log("=== Phase 2: Deploying Registry & Router ===");
        registry = new ActionRegistry(address(timelock));
        console.log("ActionRegistry:", address(registry));
        router = new AgentActionRouter(address(registry), address(timelock));
        console.log("AgentActionRouter:", address(router));
        console.log("=== Phase 3: Deploying Core Wallet Contracts ===");
        walletImplementation = new YieldSeekerAgentWallet();
        console.log("YieldSeekerAgentWallet (implementation):", address(walletImplementation));
        factory = new YieldSeekerAgentWalletFactory(address(walletImplementation), address(timelock));
        console.log("YieldSeekerAgentWalletFactory:", address(factory));
        console.log("=== Phase 4: Deploying Adapters ===");
        erc4626Adapter = new ERC4626Adapter(address(registry));
        console.log("ERC4626Adapter:", address(erc4626Adapter));
        aaveV3Adapter = new AaveV3Adapter(address(registry));
        console.log("AaveV3Adapter:", address(aaveV3Adapter));
        vm.stopBroadcast();
        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("========================================");
        console.log("Next: Run ScheduleTimelockOperations, wait 24h, then ExecuteTimelockOperations");
    }
}

/// @title ScheduleTimelockOperations
/// @notice Schedules all configuration operations through the timelock
/// @dev Run AFTER DeployYieldSeeker. Wait 24h then run ExecuteTimelockOperations.
contract ScheduleTimelockOperations is Script {
    bytes32 constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");

    struct Config {
        YieldSeekerAdminTimelock timelock;
        address registry;
        address router;
        address factory;
        address erc4626Adapter;
        address aaveV3Adapter;
        address emergency;
        address operator;
    }

    function run() external {
        Config memory c = _loadConfig();
        uint256 delay = c.timelock.getMinDelay();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 opIndex = _scheduleEmergencyRoles(c, delay, 0);
        opIndex = _scheduleFactoryConfig(c, delay, opIndex);
        opIndex = _scheduleOperator(c, delay, opIndex);
        opIndex = _scheduleAdapters(c, delay, opIndex);
        opIndex = _scheduleTargets(c, delay, opIndex);
        vm.stopBroadcast();
        console.log("Scheduled operations:", opIndex);
        console.log("Delay (seconds):", delay);
    }

    function _loadConfig() internal view returns (Config memory) {
        return Config({
            timelock: YieldSeekerAdminTimelock(payable(vm.envAddress("TIMELOCK_ADDRESS"))),
            registry: vm.envAddress("REGISTRY_ADDRESS"),
            router: vm.envAddress("ROUTER_ADDRESS"),
            factory: vm.envAddress("FACTORY_ADDRESS"),
            erc4626Adapter: vm.envAddress("ERC4626_ADAPTER"),
            aaveV3Adapter: vm.envAddress("AAVEV3_ADAPTER"),
            emergency: vm.envAddress("EMERGENCY_ADDRESS"),
            operator: vm.envAddress("OPERATOR_ADDRESS")
        });
    }

    function _scheduleEmergencyRoles(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling EMERGENCY_ROLE grants...");
        c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.router, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
        return idx;
    }

    function _scheduleFactoryConfig(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling factory configuration...");
        c.timelock.schedule(c.factory, 0, abi.encodeWithSignature("setDefaultExecutor(address)", c.router), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.factory, 0, abi.encodeWithSignature("grantRole(bytes32,address)", AGENT_CREATOR_ROLE, c.operator), bytes32(0), _salt(idx++), delay);
        return idx;
    }

    function _scheduleOperator(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling operator addition...");
        c.timelock.schedule(c.router, 0, abi.encodeWithSignature("addOperator(address)", c.operator), bytes32(0), _salt(idx++), delay);
        return idx;
    }

    function _scheduleAdapters(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling adapter registration...");
        c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("registerAdapter(address)", c.erc4626Adapter), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("registerAdapter(address)", c.aaveV3Adapter), bytes32(0), _salt(idx++), delay);
        return idx;
    }

    function _scheduleTargets(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling target registration...");
        address aavePool = vm.envOr("AAVE_V3_POOL", address(0));
        if (aavePool != address(0)) {
            c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", aavePool, c.aaveV3Adapter), bytes32(0), _salt(idx++), delay);
        }
        address yearnVault = vm.envOr("YEARN_USDC_VAULT", address(0));
        if (yearnVault != address(0)) {
            c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", yearnVault, c.erc4626Adapter), bytes32(0), _salt(idx++), delay);
        }
        address metamorphoVault = vm.envOr("METAMORPHO_USDC_VAULT", address(0));
        if (metamorphoVault != address(0)) {
            c.timelock.schedule(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", metamorphoVault, c.erc4626Adapter), bytes32(0), _salt(idx++), delay);
        }
        return idx;
    }

    function _salt(uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("YieldSeeker-Deploy-v1-", index));
    }
}

/// @title ExecuteTimelockOperations
/// @notice Executes all scheduled timelock operations after delay has passed
/// @dev Run 24h+ after ScheduleTimelockOperations
contract ExecuteTimelockOperations is Script {
    bytes32 constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");

    struct Config {
        YieldSeekerAdminTimelock timelock;
        address registry;
        address router;
        address factory;
        address erc4626Adapter;
        address aaveV3Adapter;
        address emergency;
        address operator;
    }

    function run() external {
        Config memory c = _loadConfig();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 opIndex = _executeEmergencyRoles(c, 0);
        opIndex = _executeFactoryConfig(c, opIndex);
        opIndex = _executeOperator(c, opIndex);
        opIndex = _executeAdapters(c, opIndex);
        opIndex = _executeTargets(c, opIndex);
        vm.stopBroadcast();
        console.log("Executed operations:", opIndex);
        console.log("Deployment complete!");
    }

    function _loadConfig() internal view returns (Config memory) {
        return Config({
            timelock: YieldSeekerAdminTimelock(payable(vm.envAddress("TIMELOCK_ADDRESS"))),
            registry: vm.envAddress("REGISTRY_ADDRESS"),
            router: vm.envAddress("ROUTER_ADDRESS"),
            factory: vm.envAddress("FACTORY_ADDRESS"),
            erc4626Adapter: vm.envAddress("ERC4626_ADAPTER"),
            aaveV3Adapter: vm.envAddress("AAVEV3_ADAPTER"),
            emergency: vm.envAddress("EMERGENCY_ADDRESS"),
            operator: vm.envAddress("OPERATOR_ADDRESS")
        });
    }

    function _executeEmergencyRoles(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing EMERGENCY_ROLE grants...");
        c.timelock.execute(c.registry, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
        c.timelock.execute(c.router, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
        return idx;
    }

    function _executeFactoryConfig(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing factory configuration...");
        c.timelock.execute(c.factory, 0, abi.encodeWithSignature("setDefaultExecutor(address)", c.router), bytes32(0), _salt(idx++));
        c.timelock.execute(c.factory, 0, abi.encodeWithSignature("grantRole(bytes32,address)", AGENT_CREATOR_ROLE, c.operator), bytes32(0), _salt(idx++));
        return idx;
    }

    function _executeOperator(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing operator addition...");
        c.timelock.execute(c.router, 0, abi.encodeWithSignature("addOperator(address)", c.operator), bytes32(0), _salt(idx++));
        return idx;
    }

    function _executeAdapters(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing adapter registration...");
        c.timelock.execute(c.registry, 0, abi.encodeWithSignature("registerAdapter(address)", c.erc4626Adapter), bytes32(0), _salt(idx++));
        c.timelock.execute(c.registry, 0, abi.encodeWithSignature("registerAdapter(address)", c.aaveV3Adapter), bytes32(0), _salt(idx++));
        return idx;
    }

    function _executeTargets(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing target registration...");
        address aavePool = vm.envOr("AAVE_V3_POOL", address(0));
        if (aavePool != address(0)) {
            c.timelock.execute(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", aavePool, c.aaveV3Adapter), bytes32(0), _salt(idx++));
        }
        address yearnVault = vm.envOr("YEARN_USDC_VAULT", address(0));
        if (yearnVault != address(0)) {
            c.timelock.execute(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", yearnVault, c.erc4626Adapter), bytes32(0), _salt(idx++));
        }
        address metamorphoVault = vm.envOr("METAMORPHO_USDC_VAULT", address(0));
        if (metamorphoVault != address(0)) {
            c.timelock.execute(c.registry, 0, abi.encodeWithSignature("registerTarget(address,address)", metamorphoVault, c.erc4626Adapter), bytes32(0), _salt(idx++));
        }
        return idx;
    }

    function _salt(uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("YieldSeeker-Deploy-v1-", index));
    }
}
