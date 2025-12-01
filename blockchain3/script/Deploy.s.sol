// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAdminTimelock} from "../src/YieldSeekerAdminTimelock.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {ERC4626VaultWrapper} from "../src/vaults/ERC4626VaultWrapper.sol";
import {AaveV3VaultWrapper} from "../src/vaults/AaveV3VaultWrapper.sol";
import {MerklValidator} from "../src/validators/MerklValidator.sol";
import {ZeroExValidator} from "../src/validators/ZeroExValidator.sol";

/// @title DeployYieldSeeker
/// @notice Deploys the full YieldSeeker smart wallet infrastructure
/// @dev Run with: forge script script/Deploy.s.sol:DeployYieldSeeker --rpc-url <RPC> --broadcast
///
/// Required environment variables:
///   DEPLOYER_PRIVATE_KEY    - Private key for deployment transactions
///   PROPOSER_ADDRESS        - Multisig that can schedule timelock operations
///   EXECUTOR_ADDRESS        - Multisig that can execute timelock operations
///   AAVE_V3_POOL            - Aave V3 Pool address for this chain
///
/// After deployment, run ScheduleTimelockOperations with additional env vars,
/// then wait 24h and run ExecuteTimelockOperations.
contract DeployYieldSeeker is Script {
    YieldSeekerAdminTimelock public timelock;
    YieldSeekerAgentWallet public walletImplementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionPolicy public policy;
    AgentActionRouter public router;
    ERC4626VaultWrapper public erc4626Wrapper;
    AaveV3VaultWrapper public aaveWrapper;
    MerklValidator public merklValidator;
    ZeroExValidator public zeroExValidator;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proposer = vm.envAddress("PROPOSER_ADDRESS");
        address executor = vm.envAddress("EXECUTOR_ADDRESS");
        address aavePool = vm.envAddress("AAVE_V3_POOL");
        vm.startBroadcast(deployerKey);
        console.log("=== Phase 1: Deploying Timelock ===");
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new YieldSeekerAdminTimelock(proposers, executors, address(0));
        console.log("YieldSeekerAdminTimelock:", address(timelock));
        console.log("=== Phase 2: Deploying Core Contracts ===");
        policy = new AgentActionPolicy(address(timelock));
        console.log("AgentActionPolicy:", address(policy));
        router = new AgentActionRouter(address(policy), address(timelock));
        console.log("AgentActionRouter:", address(router));
        walletImplementation = new YieldSeekerAgentWallet();
        console.log("YieldSeekerAgentWallet (implementation):", address(walletImplementation));
        factory = new YieldSeekerAgentWalletFactory(address(walletImplementation), address(timelock));
        console.log("YieldSeekerAgentWalletFactory:", address(factory));
        console.log("=== Phase 3: Deploying Vault Wrappers ===");
        erc4626Wrapper = new ERC4626VaultWrapper(address(timelock));
        console.log("ERC4626VaultWrapper:", address(erc4626Wrapper));
        aaveWrapper = new AaveV3VaultWrapper(aavePool, address(timelock));
        console.log("AaveV3VaultWrapper:", address(aaveWrapper));
        console.log("=== Phase 4: Deploying Validators ===");
        merklValidator = new MerklValidator();
        console.log("MerklValidator:", address(merklValidator));
        zeroExValidator = new ZeroExValidator();
        console.log("ZeroExValidator:", address(zeroExValidator));
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
    bytes4 constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(address,uint256)"));
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(address,uint256)"));
    bytes4 constant CLAIM_SELECTOR = 0x3d13f874;
    bytes4 constant TRANSFORM_ERC20_SELECTOR = 0x415565b0;

    struct Config {
        YieldSeekerAdminTimelock timelock;
        address router;
        address policy;
        address factory;
        address erc4626Wrapper;
        address aaveWrapper;
        address merklValidator;
        address zeroExValidator;
        address emergency;
        address operator;
        address usdc;
        address aUsdc;
    }

    function run() external {
        Config memory c = _loadConfig();
        uint256 delay = c.timelock.getMinDelay();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 opIndex = _scheduleEmergencyRoles(c, delay, 0);
        opIndex = _scheduleFactoryConfig(c, delay, opIndex);
        opIndex = _scheduleOperator(c, delay, opIndex);
        opIndex = _scheduleVaults(c, delay, opIndex);
        opIndex = _schedulePolicies(c, delay, opIndex);
        vm.stopBroadcast();
        console.log("Scheduled operations:", opIndex);
        console.log("Delay (seconds):", delay);
    }

    function _loadConfig() internal view returns (Config memory) {
        return Config({
            timelock: YieldSeekerAdminTimelock(payable(vm.envAddress("TIMELOCK_ADDRESS"))),
            router: vm.envAddress("ROUTER_ADDRESS"),
            policy: vm.envAddress("POLICY_ADDRESS"),
            factory: vm.envAddress("FACTORY_ADDRESS"),
            erc4626Wrapper: vm.envAddress("ERC4626_WRAPPER"),
            aaveWrapper: vm.envAddress("AAVE_WRAPPER"),
            merklValidator: vm.envAddress("MERKL_VALIDATOR"),
            zeroExValidator: vm.envAddress("ZEROEX_VALIDATOR"),
            emergency: vm.envAddress("EMERGENCY_ADDRESS"),
            operator: vm.envAddress("OPERATOR_ADDRESS"),
            usdc: vm.envAddress("USDC_ADDRESS"),
            aUsdc: vm.envAddress("AUSDC_ADDRESS")
        });
    }

    function _scheduleEmergencyRoles(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling EMERGENCY_ROLE grants...");
        c.timelock.schedule(c.router, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.erc4626Wrapper, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.aaveWrapper, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++), delay);
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

    function _scheduleVaults(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling vault whitelisting...");
        c.timelock.schedule(c.aaveWrapper, 0, abi.encodeWithSignature("addAsset(address,address)", c.usdc, c.aUsdc), bytes32(0), _salt(idx++), delay);
        address yearnVault = vm.envOr("YEARN_USDC_VAULT", address(0));
        if (yearnVault != address(0)) {
            c.timelock.schedule(c.erc4626Wrapper, 0, abi.encodeWithSignature("addVault(address)", yearnVault), bytes32(0), _salt(idx++), delay);
        }
        address metamorphoVault = vm.envOr("METAMORPHO_USDC_VAULT", address(0));
        if (metamorphoVault != address(0)) {
            c.timelock.schedule(c.erc4626Wrapper, 0, abi.encodeWithSignature("addVault(address)", metamorphoVault), bytes32(0), _salt(idx++), delay);
        }
        return idx;
    }

    function _schedulePolicies(Config memory c, uint256 delay, uint256 idx) internal returns (uint256) {
        console.log("Scheduling policy configuration...");
        c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.erc4626Wrapper, DEPOSIT_SELECTOR, c.erc4626Wrapper), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.erc4626Wrapper, WITHDRAW_SELECTOR, c.erc4626Wrapper), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.aaveWrapper, DEPOSIT_SELECTOR, c.aaveWrapper), bytes32(0), _salt(idx++), delay);
        c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.aaveWrapper, WITHDRAW_SELECTOR, c.aaveWrapper), bytes32(0), _salt(idx++), delay);
        address merklDistributor = vm.envOr("MERKL_DISTRIBUTOR", address(0));
        if (merklDistributor != address(0)) {
            c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", merklDistributor, CLAIM_SELECTOR, c.merklValidator), bytes32(0), _salt(idx++), delay);
        }
        address zeroExExchange = vm.envOr("ZEROEX_EXCHANGE", address(0));
        if (zeroExExchange != address(0)) {
            c.timelock.schedule(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", zeroExExchange, TRANSFORM_ERC20_SELECTOR, c.zeroExValidator), bytes32(0), _salt(idx++), delay);
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
    bytes4 constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(address,uint256)"));
    bytes4 constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(address,uint256)"));
    bytes4 constant CLAIM_SELECTOR = 0x3d13f874;
    bytes4 constant TRANSFORM_ERC20_SELECTOR = 0x415565b0;

    struct Config {
        YieldSeekerAdminTimelock timelock;
        address router;
        address policy;
        address factory;
        address erc4626Wrapper;
        address aaveWrapper;
        address merklValidator;
        address zeroExValidator;
        address emergency;
        address operator;
        address usdc;
        address aUsdc;
    }

    function run() external {
        Config memory c = _loadConfig();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        uint256 opIndex = _executeEmergencyRoles(c, 0);
        opIndex = _executeFactoryConfig(c, opIndex);
        opIndex = _executeOperator(c, opIndex);
        opIndex = _executeVaults(c, opIndex);
        opIndex = _executePolicies(c, opIndex);
        vm.stopBroadcast();
        console.log("Executed operations:", opIndex);
        console.log("Deployment complete!");
    }

    function _loadConfig() internal view returns (Config memory) {
        return Config({
            timelock: YieldSeekerAdminTimelock(payable(vm.envAddress("TIMELOCK_ADDRESS"))),
            router: vm.envAddress("ROUTER_ADDRESS"),
            policy: vm.envAddress("POLICY_ADDRESS"),
            factory: vm.envAddress("FACTORY_ADDRESS"),
            erc4626Wrapper: vm.envAddress("ERC4626_WRAPPER"),
            aaveWrapper: vm.envAddress("AAVE_WRAPPER"),
            merklValidator: vm.envAddress("MERKL_VALIDATOR"),
            zeroExValidator: vm.envAddress("ZEROEX_VALIDATOR"),
            emergency: vm.envAddress("EMERGENCY_ADDRESS"),
            operator: vm.envAddress("OPERATOR_ADDRESS"),
            usdc: vm.envAddress("USDC_ADDRESS"),
            aUsdc: vm.envAddress("AUSDC_ADDRESS")
        });
    }

    function _executeEmergencyRoles(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing EMERGENCY_ROLE grants...");
        c.timelock.execute(c.router, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
        c.timelock.execute(c.policy, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
        c.timelock.execute(c.erc4626Wrapper, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
        c.timelock.execute(c.aaveWrapper, 0, abi.encodeWithSignature("grantRole(bytes32,address)", EMERGENCY_ROLE, c.emergency), bytes32(0), _salt(idx++));
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

    function _executeVaults(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing vault whitelisting...");
        c.timelock.execute(c.aaveWrapper, 0, abi.encodeWithSignature("addAsset(address,address)", c.usdc, c.aUsdc), bytes32(0), _salt(idx++));
        address yearnVault = vm.envOr("YEARN_USDC_VAULT", address(0));
        if (yearnVault != address(0)) {
            c.timelock.execute(c.erc4626Wrapper, 0, abi.encodeWithSignature("addVault(address)", yearnVault), bytes32(0), _salt(idx++));
        }
        address metamorphoVault = vm.envOr("METAMORPHO_USDC_VAULT", address(0));
        if (metamorphoVault != address(0)) {
            c.timelock.execute(c.erc4626Wrapper, 0, abi.encodeWithSignature("addVault(address)", metamorphoVault), bytes32(0), _salt(idx++));
        }
        return idx;
    }

    function _executePolicies(Config memory c, uint256 idx) internal returns (uint256) {
        console.log("Executing policy configuration...");
        c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.erc4626Wrapper, DEPOSIT_SELECTOR, c.erc4626Wrapper), bytes32(0), _salt(idx++));
        c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.erc4626Wrapper, WITHDRAW_SELECTOR, c.erc4626Wrapper), bytes32(0), _salt(idx++));
        c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.aaveWrapper, DEPOSIT_SELECTOR, c.aaveWrapper), bytes32(0), _salt(idx++));
        c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", c.aaveWrapper, WITHDRAW_SELECTOR, c.aaveWrapper), bytes32(0), _salt(idx++));
        address merklDistributor = vm.envOr("MERKL_DISTRIBUTOR", address(0));
        if (merklDistributor != address(0)) {
            c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", merklDistributor, CLAIM_SELECTOR, c.merklValidator), bytes32(0), _salt(idx++));
        }
        address zeroExExchange = vm.envOr("ZEROEX_EXCHANGE", address(0));
        if (zeroExExchange != address(0)) {
            c.timelock.execute(c.policy, 0, abi.encodeWithSignature("addPolicy(address,bytes4,address)", zeroExExchange, TRANSFORM_ERC20_SELECTOR, c.zeroExValidator), bytes32(0), _salt(idx++));
        }
        return idx;
    }

    function _salt(uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("YieldSeeker-Deploy-v1-", index));
    }
}
