// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerZeroXAdapter as ZeroXAdapter} from "../src/adapters/ZeroXAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DeployScript
 * @notice Deploys the YieldSeeker AgentWallet system with selective contract deployment.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast
 *
 * SELECTIVE DEPLOYMENT:
 * This script reads from deployments.json and only deploys contracts with address(0) entries.
 * To redeploy a specific contract, set its address to 0x0000000000000000000000000000000000000000 in deployments.json, then re-run.
 *
 * Example deployments.json:
 * {
 *   "adminTimelock": "0x0000000000000000000000000000000000000000",
 *   "agentWalletFactory": "0x0000000000000000000000000000000000000000",
 *   "adapterRegistry": "0x0000000000000000000000000000000000000000",
 *   "agentWalletImplementation": "0x0000000000000000000000000000000000000000",
 *   "feeTracker": "0x0000000000000000000000000000000000000000",
 *   "erc4626Adapter": "0x0000000000000000000000000000000000000000",
 *   "zeroXAdapter": "0x0000000000000000000000000000000000000000"
 * }
 *
 * In this example, only the Factory and Implementation would be redeployed.
 */
contract DeployScript is Script {
    using stdJson for string;
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    uint256 constant SALT = 0x4;

    // Testing Mode: Set to true to deploy with 0-delay adminTimelock for faster testing
    // Set to false for production (uses 72-hour delay)
    bool constant TESTING_MODE = true;

    /**
     * @notice Get 0x AllowanceHolder address for a given chain
     * @dev See https://github.com/0xProject/0x-settler/blob/master/README.md#allowanceholder-addresses
     * AllowanceHolder serves as BOTH the allowance target and entry point for swaps.
     */
    function getZeroXAllowanceTarget(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) return 0x0000000000001fF3684f28c67538d4D072C22734; // Base
        if (chainId == 84532) return 0x0000000000001fF3684f28c67538d4D072C22734; // Base Sepolia
        revert("Unsupported chain for 0x");
    }

    // State tracking
    struct Deployments {
        address adminTimelock;
        address agentWalletFactory;
        address adapterRegistry;
        address agentWalletImplementation;
        address feeTracker;
        address erc4626Adapter;
        address zeroXAdapter;
    }

    /**
     * @notice Safely read an address from JSON, returning address(0) if the key doesn't exist
     */
    function safeReadAddress(string memory json, string memory key) internal pure returns (address) {
        try vm.parseJsonAddress(json, key) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    function run() public {
        address serverAddress = vm.envAddress("SERVER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console2.log("=================================================");
        console2.log("YIELDSEEKER DEPLOYMENT SCRIPT");
        console2.log("=================================================");
        console2.log("Deployer:", deployerAddress);
        console2.log("Server:", serverAddress);
        console2.log("Testing Mode:", TESTING_MODE ? "YES (0-delay)" : "NO (72-hour delay)");
        console2.log("");

        // Load existing deployments from JSON
        Deployments memory deployments;
        string memory path = "./deployments.json";
        if (vm.exists(path)) {
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory deployJson = vm.readFile(path);
            deployments = Deployments({
                adminTimelock: safeReadAddress(deployJson, ".adminTimelock"),
                agentWalletFactory: safeReadAddress(deployJson, ".agentWalletFactory"),
                adapterRegistry: safeReadAddress(deployJson, ".adapterRegistry"),
                agentWalletImplementation: safeReadAddress(deployJson, ".agentWalletImplementation"),
                feeTracker: safeReadAddress(deployJson, ".feeTracker"),
                erc4626Adapter: safeReadAddress(deployJson, ".erc4626Adapter"),
                zeroXAdapter: safeReadAddress(deployJson, ".zeroXAdapter")
            });
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy or reuse AdminTimelock
        if (deployments.adminTimelock == address(0)) {
            address[] memory proposers = new address[](1);
            proposers[0] = deployerAddress;
            address[] memory executors = new address[](1);
            executors[0] = deployerAddress;
            uint256 delay = TESTING_MODE ? 0 : 72 hours;
            AdminTimelock newAdminTimelock = new AdminTimelock{salt: bytes32(SALT)}(delay, proposers, executors, address(0));
            deployments.adminTimelock = address(newAdminTimelock);
            console2.log("-> AdminTimelock deployed at:", address(newAdminTimelock));
            console2.log("   delay (seconds):", delay);
        } else {
            console2.log("-> Using existing adminTimelock:", deployments.adminTimelock);
        }

        // Deploy or reuse AgentWalletFactory
        if (deployments.agentWalletFactory == address(0)) {
            AgentWalletFactory newAgentWalletFactory = new AgentWalletFactory{salt: bytes32(SALT)}(deployments.adminTimelock, serverAddress);
            deployments.agentWalletFactory = address(newAgentWalletFactory);
            console2.log("-> AgentWalletFactory deployed at:", address(newAgentWalletFactory));
            console2.log("   AGENT_OPERATOR_ROLE granted to:", serverAddress);
        } else {
            console2.log("-> Using existing agentWalletFactory:", deployments.agentWalletFactory);
        }

        // Deploy or reuse AgentWallet Implementation
        if (deployments.agentWalletImplementation == address(0)) {
            AgentWallet newAgentWalletImplementation = new AgentWallet{salt: bytes32(SALT)}(deployments.agentWalletFactory);
            deployments.agentWalletImplementation = address(newAgentWalletImplementation);
            console2.log("-> AgentWallet Implementation deployed at:", address(newAgentWalletImplementation));
        } else {
            console2.log("-> Using existing agentWalletImplementation:", deployments.agentWalletImplementation);
        }

        // Deploy or reuse AdapterRegistry
        if (deployments.adapterRegistry == address(0)) {
            AdapterRegistry newAdapterRegistry = new AdapterRegistry{salt: bytes32(SALT)}(deployments.adminTimelock, deployerAddress);
            deployments.adapterRegistry = address(newAdapterRegistry);
            console2.log("-> AdapterRegistry deployed at:", address(newAdapterRegistry));
        } else {
            console2.log("-> Using existing adapterRegistry:", deployments.adapterRegistry);
        }

        // Deploy or reuse FeeTracker
        if (deployments.feeTracker == address(0)) {
            FeeTracker newFeeTracker = new FeeTracker{salt: bytes32(SALT)}(deployments.adminTimelock);
            deployments.feeTracker = address(newFeeTracker);
            console2.log("-> FeeTracker deployed at:", address(newFeeTracker));
        } else {
            console2.log("-> Using existing feeTracker:", deployments.feeTracker);
        }

        // Deploy or reuse ERC4626 AdaptgetZeroXAllowanceTarget(block.chainid
        if (deployments.erc4626Adapter == address(0)) {
            ERC4626Adapter erc4626Adapter = new ERC4626Adapter{salt: bytes32(SALT)}();
            deployments.erc4626Adapter = address(erc4626Adapter);
            console2.log("-> ERC4626Adapter deployed at:", address(erc4626Adapter));
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        // Deploy or reuse ZeroX Adapter
        address zeroXAllowanceTarget = getZeroXAllowanceTarget(block.chainid);
        if (deployments.zeroXAdapter == address(0)) {
            ZeroXAdapter zeroXAdapter = new ZeroXAdapter{salt: bytes32(SALT)}(zeroXAllowanceTarget);
            deployments.zeroXAdapter = address(zeroXAdapter);
            console2.log("-> ZeroXAdapter deployed at:", address(zeroXAdapter));
            console2.log("   allowanceTarget:", zeroXAllowanceTarget);
        } else {
            console2.log("-> Using existing zeroXAdapter:", deployments.zeroXAdapter);
            console2.log("   allowanceTarget:", ZeroXAdapter(deployments.zeroXAdapter).ALLOWANCE_TARGET());
        }

        // Export deployments to JSON
        string memory json = "json";
        vm.serializeAddress(json, "adminTimelock", deployments.adminTimelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.agentWalletFactory);
        vm.serializeAddress(json, "adapterRegistry", deployments.adapterRegistry);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.agentWalletImplementation);
        vm.serializeAddress(json, "feeTracker", deployments.feeTracker);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        string memory finalJson = vm.serializeAddress(json, "zeroXAdapter", deployments.zeroXAdapter);
        vm.writeJson(finalJson, "./deployments.json");
        console2.log("-> Deployments saved to ./deployments.json");

        // Post-deployment configuration
        console2.log("");
        console2.log("=================================================");
        console2.log("POST-DEPLOYMENT CONFIGURATION");
        console2.log("=================================================");
        AdapterRegistry adapterRegistry = AdapterRegistry(deployments.adapterRegistry);
        AgentWalletFactory agentWalletFactory = AgentWalletFactory(deployments.agentWalletFactory);
        AdminTimelock adminTimelock = AdminTimelock(payable(deployments.adminTimelock));
        uint256 timelockDelay = adminTimelock.getMinDelay();

        // Collect all operations to batch
        address[] memory targets = new address[](7);
        bytes[] memory datas = new bytes[](7);
        uint256 operationCount = 0;

        // 1. Configure Factory
        console2.log("-> Preparing agentWalletFactory configuration...");
        if (address(agentWalletFactory.agentWalletImplementation()) != deployments.agentWalletImplementation) {
            targets[operationCount] = deployments.agentWalletFactory;
            datas[operationCount] = abi.encodeCall(agentWalletFactory.setAgentWalletImplementation, (AgentWallet(payable(deployments.agentWalletImplementation))));
            operationCount++;
        }
        if (address(agentWalletFactory.adapterRegistry()) != deployments.adapterRegistry) {
            targets[operationCount] = deployments.agentWalletFactory;
            datas[operationCount] = abi.encodeCall(agentWalletFactory.setAdapterRegistry, (adapterRegistry));
            operationCount++;
        }
        if (address(agentWalletFactory.feeTracker()) != deployments.feeTracker) {
            targets[operationCount] = deployments.agentWalletFactory;
            datas[operationCount] = abi.encodeCall(agentWalletFactory.setFeeTracker, (FeeTracker(deployments.feeTracker)));
            operationCount++;
        }
        // 2. Register Adapters
        console2.log("-> Preparing adapter registration...");
        if (!adapterRegistry.isRegisteredAdapter(deployments.erc4626Adapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.erc4626Adapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.zeroXAdapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.zeroXAdapter));
            operationCount++;
        }
        // 3. Set Agent Operator
        if (!agentWalletFactory.hasRole(agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)) {
            console2.log("-> Preparing AGENT_OPERATOR_ROLE grant for server:", serverAddress);
            targets[operationCount] = deployments.agentWalletFactory;
            datas[operationCount] = abi.encodeCall(agentWalletFactory.grantRole, (agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress));
            operationCount++;
        } else {
            console2.log("-> Server already has AGENT_OPERATOR_ROLE");
        }
        // Execute batch if there are operations
        if (operationCount > 0) {
            // Resize arrays to actual operation count
            address[] memory batchTargets = new address[](operationCount);
            uint256[] memory batchValues = new uint256[](operationCount);
            bytes[] memory batchDatas = new bytes[](operationCount);
            for (uint256 i = 0; i < operationCount; i++) {
                batchTargets[i] = targets[i];
                batchValues[i] = 0;
                batchDatas[i] = datas[i];
            }
            console2.log("-> Executing", operationCount, "operations in batch...");
            scheduleAndExecuteBatch(adminTimelock, batchTargets, batchValues, batchDatas, timelockDelay, bytes32(uint256(1000)));
            console2.log("-> Configuration complete!");
        } else {
            console2.log("-> No configuration needed, all settings are up to date!");
        }
        console2.log("=================================================");
        console2.log("You will need to register any specific vaults manually");
        console2.log("=================================================");
        vm.stopBroadcast();
    }

    function scheduleAndExecuteBatch(AdminTimelock adminTimelock, address[] memory targets, uint256[] memory values, bytes[] memory datas, uint256 delay, bytes32 salt) internal {
        if (delay == 0) {
            // Testing mode: execute directly
            adminTimelock.scheduleBatch(targets, values, datas, bytes32(0), salt, 0);
            adminTimelock.executeBatch(targets, values, datas, bytes32(0), salt);
        } else {
            // Production mode: only schedule (need to execute later)
            adminTimelock.scheduleBatch(targets, values, datas, bytes32(0), salt, delay);
            console2.log("   Scheduled batch operation with salt:", vm.toString(salt));
            console2.log("   Execute after delay:", delay);
        }
    }
}
