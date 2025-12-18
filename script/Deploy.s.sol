// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
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
 *   "erc4626Adapter": "0x0000000000000000000000000000000000000000",
 *   "aaveV3Adapter": "0x0000000000000000000000000000000000000000"
 * }
 *
 * In this example, only the Factory and Implementation would be redeployed.
 */
contract DeployScript is Script {
    using stdJson for string;
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    uint256 constant SALT = 0x3;

    // Testing Mode: Set to true to deploy with 0-delay adminTimelock for faster testing
    // Set to false for production (uses 72-hour delay)
    bool constant TESTING_MODE = true;

    // State tracking
    struct Deployments {
        address adminTimelock;
        address agentWalletFactory;
        address adapterRegistry;
        address agentWalletImplementation;
        address erc4626Adapter;
        address aaveV3Adapter;
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
                adminTimelock: deployJson.readAddress(".adminTimelock"),
                agentWalletFactory: deployJson.readAddress(".agentWalletFactory"),
                adapterRegistry: deployJson.readAddress(".adapterRegistry"),
                agentWalletImplementation: deployJson.readAddress(".agentWalletImplementation"),
                erc4626Adapter: deployJson.readAddress(".erc4626Adapter"),
                aaveV3Adapter: deployJson.readAddress(".aaveV3Adapter")
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

        // Deploy or reuse ERC4626 Adapter
        if (deployments.erc4626Adapter == address(0)) {
            ERC4626Adapter erc4626Adapter = new ERC4626Adapter{salt: bytes32(SALT)}();
            deployments.erc4626Adapter = address(erc4626Adapter);
            console2.log("-> ERC4626Adapter deployed at:", address(erc4626Adapter));
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        // Deploy or reuse Aave V3 Adapter
        if (deployments.aaveV3Adapter == address(0)) {
            AaveV3Adapter aaveV3Adapter = new AaveV3Adapter{salt: bytes32(SALT)}();
            deployments.aaveV3Adapter = address(aaveV3Adapter);
            console2.log("-> AaveV3Adapter deployed at:", address(aaveV3Adapter));
        } else {
            console2.log("-> Using existing aaveV3Adapter:", deployments.aaveV3Adapter);
        }

        // Export deployments to JSON
        string memory json = "json";
        vm.serializeAddress(json, "adminTimelock", deployments.adminTimelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.agentWalletFactory);
        vm.serializeAddress(json, "adapterRegistry", deployments.adapterRegistry);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.agentWalletImplementation);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        string memory finalJson = vm.serializeAddress(json, "aaveV3Adapter", deployments.aaveV3Adapter);
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
        // 1. Configure Factory
        console2.log("-> Syncing agentWalletFactory configuration...");
        if (address(agentWalletFactory.agentWalletImplementation()) != deployments.agentWalletImplementation) {
            scheduleAndExecute(
                adminTimelock, deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAgentWalletImplementation, (AgentWallet(payable(deployments.agentWalletImplementation)))), timelockDelay, bytes32(uint256(1000))
            );
        }
        if (address(agentWalletFactory.adapterRegistry()) != deployments.adapterRegistry) {
            scheduleAndExecute(adminTimelock, deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAdapterRegistry, (adapterRegistry)), timelockDelay, bytes32(uint256(1001)));
        }
        // 2. Register Adapters
        console2.log("-> Checking adapter registration...");
        if (!adapterRegistry.isRegisteredAdapter(deployments.erc4626Adapter)) {
            scheduleAndExecute(adminTimelock, deployments.adapterRegistry, abi.encodeCall(adapterRegistry.registerAdapter, (deployments.erc4626Adapter)), timelockDelay, bytes32(uint256(1002)));
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.aaveV3Adapter)) {
            scheduleAndExecute(adminTimelock, deployments.adapterRegistry, abi.encodeCall(adapterRegistry.registerAdapter, (deployments.aaveV3Adapter)), timelockDelay, bytes32(uint256(1003)));
        }
        // 3. Set Agent Operator
        if (!agentWalletFactory.hasRole(agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)) {
            console2.log("-> Granting AGENT_OPERATOR_ROLE to server:", serverAddress);
            scheduleAndExecute(adminTimelock, deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.grantRole, (agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)), timelockDelay, bytes32(uint256(1004)));
        } else {
            console2.log("-> Server already has AGENT_OPERATOR_ROLE");
        }
        console2.log("-> Configuration complete!");
        console2.log("=================================================");
        console2.log("You will need to register any specific vaults manually");
        console2.log("=================================================");

        vm.stopBroadcast();
    }

    function scheduleAndExecute(AdminTimelock adminTimelock, address target, bytes memory data, uint256 delay, bytes32 salt) internal {
        if (delay == 0) {
            // Testing mode: execute directly
            adminTimelock.schedule(target, 0, data, bytes32(0), salt, 0);
            adminTimelock.execute(target, 0, data, bytes32(0), salt);
        } else {
            // Production mode: only schedule (need to execute later)
            adminTimelock.schedule(target, 0, data, bytes32(0), salt, delay);
            console2.log("   Scheduled operation with salt:", vm.toString(salt));
            console2.log("   Execute after delay:", delay);
        }
    }
}
