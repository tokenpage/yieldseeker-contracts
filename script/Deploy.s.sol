// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerActionRegistry} from "../src/ActionRegistry.sol";
import {YieldSeekerAdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {IEntryPoint} from "../src/erc4337/IEntryPoint.sol";
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
 *   "adminTimelock": "0x...",
 *   "agentWalletFactory": "0x0000000000000000000000000000000000000000",
 *   "actionRegistry": "0x...",
 *   "agentWalletImplementation": "0x0000000000000000000000000000000000000000",
 *   "erc4626Adapter": "0x...",
 *   "aaveV3Adapter": "0x..."
 * }
 *
 * In this example, only the Factory and Implementation would be redeployed.
 */
contract DeployScript is Script {
    using stdJson for string;
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    uint256 constant SALT = 0x1;

    // Testing Mode: Set to true to deploy with 0-delay timelock for faster testing
    // Set to false for production (uses 72-hour delay)
    bool constant TESTING_MODE = true;

    // State tracking
    struct Deployments {
        address timelock;
        address factory;
        address registry;
        address implementation;
        address erc4626Adapter;
        address aaveV3Adapter;
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=================================================");
        console2.log("YIELDSEEKER DEPLOYMENT SCRIPT");
        console2.log("=================================================");
        console2.log("Deployer:", deployer);
        console2.log("Testing Mode:", TESTING_MODE ? "YES (0-delay)" : "NO (72-hour delay)");
        console2.log("");

        // Load existing deployments from JSON
        Deployments memory deployments = loadDeployments();

        vm.startBroadcast(deployerPrivateKey);

        // Deploy or reuse each contract
        if (deployments.timelock == address(0)) {
            deployments.timelock = deployTimelock(deployer);
        } else {
            console2.log("-> Using existing adminTimelock:", deployments.timelock);
        }

        if (deployments.registry == address(0)) {
            deployments.registry = deployRegistry(deployments.timelock, deployer);
        } else {
            console2.log("-> Using existing actionRegistry:", deployments.registry);
        }

        if (deployments.factory == address(0)) {
            deployments.factory = deployFactory(deployments.timelock, deployer);
        } else {
            console2.log("-> Using existing agentWalletFactory:", deployments.factory);
        }

        if (deployments.implementation == address(0)) {
            deployments.implementation = deployImplementation(deployments.factory);
        } else {
            console2.log("-> Using existing agentWalletImplementation:", deployments.implementation);
        }

        if (deployments.erc4626Adapter == address(0)) {
            deployments.erc4626Adapter = deployERC4626Adapter();
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        if (deployments.aaveV3Adapter == address(0)) {
            deployments.aaveV3Adapter = deployAaveV3Adapter();
        } else {
            console2.log("-> Using existing aaveV3Adapter:", deployments.aaveV3Adapter);
        }

        vm.stopBroadcast();
        exportDeployments(deployments);
        printDeploymentSummary(deployments);
    }

    function loadDeployments() internal view returns (Deployments memory) {
        string memory path = "./deployments.json";
        if (!vm.exists(path)) {
            return Deployments({timelock: address(0), factory: address(0), registry: address(0), implementation: address(0), erc4626Adapter: address(0), aaveV3Adapter: address(0)});
        }
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(path);
        return Deployments({
            timelock: json.readAddress(".adminTimelock"),
            factory: json.readAddress(".agentWalletFactory"),
            registry: json.readAddress(".actionRegistry"),
            implementation: json.readAddress(".agentWalletImplementation"),
            erc4626Adapter: json.readAddress(".erc4626Adapter"),
            aaveV3Adapter: json.readAddress(".aaveV3Adapter")
        });
    }

    function deployTimelock(address deployer) internal returns (address) {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        uint256 delay = TESTING_MODE ? 0 : 72 hours;
        YieldSeekerAdminTimelock timelock = new YieldSeekerAdminTimelock{salt: bytes32(SALT)}(delay, proposers, executors, address(0));
        // Make timelock self-administered (best practice)
        timelock.grantRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock));
        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        console2.log("-> AdminTimelock deployed at:", address(timelock));
        console2.log("   delay (seconds):", delay);
        return address(timelock);
    }

    function deployRegistry(address timelock, address deployer) internal returns (address) {
        YieldSeekerActionRegistry registry = new YieldSeekerActionRegistry{salt: bytes32(SALT)}(timelock, deployer);
        console2.log("-> ActionRegistry deployed at:", address(registry));
        return address(registry);
    }

    function deployFactory(address timelock, address deployer) internal returns (address) {
        YieldSeekerAgentWalletFactory factory = new YieldSeekerAgentWalletFactory{salt: bytes32(SALT)}(timelock, deployer);
        console2.log("-> YieldSeekerAgentWalletFactory deployed at:", address(factory));
        return address(factory);
    }

    function deployImplementation(address factory) internal returns (address) {
        YieldSeekerAgentWallet implementation = new YieldSeekerAgentWallet{salt: bytes32(SALT)}(IEntryPoint(ENTRYPOINT), factory);
        console2.log("-> AgentWallet Implementation deployed at:", address(implementation));
        return address(implementation);
    }

    function deployERC4626Adapter() internal returns (address) {
        YieldSeekerERC4626Adapter adapter = new YieldSeekerERC4626Adapter{salt: bytes32(SALT)}();
        console2.log("-> YieldSeekerERC4626Adapter deployed at:", address(adapter));
        return address(adapter);
    }

    function deployAaveV3Adapter() internal returns (address) {
        YieldSeekerAaveV3Adapter adapter = new YieldSeekerAaveV3Adapter{salt: bytes32(SALT)}();
        console2.log("-> YieldSeekerAaveV3Adapter deployed at:", address(adapter));
        return address(adapter);
    }

    function exportDeployments(Deployments memory deployments) internal {
        string memory json = "json";
        vm.serializeAddress(json, "adminTimelock", deployments.timelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.factory);
        vm.serializeAddress(json, "actionRegistry", deployments.registry);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.implementation);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        string memory finalJson = vm.serializeAddress(json, "aaveV3Adapter", deployments.aaveV3Adapter);
        vm.writeJson(finalJson, "./deployments.json");
        console2.log("-> Deployments saved to ./deployments.json");
    }

    function printDeploymentSummary(Deployments memory deployments) internal pure {
        console2.log("");
        console2.log("=================================================");
        console2.log("DEPLOYMENT SUMMARY");
        console2.log("=================================================");
        console2.log("adminTimelock:", deployments.timelock);
        console2.log("agentWalletFactory:", deployments.factory);
        console2.log("actionRegistry:", deployments.registry);
        console2.log("agentWalletImplementation:", deployments.implementation);
        console2.log("erc4626Adapter:", deployments.erc4626Adapter);
        console2.log("aaveV3Adapter:", deployments.aaveV3Adapter);
        console2.log("=================================================");
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("1. Configure factory via timelock:");
        console2.log("   - factory.setImplementation(implementation)");
        console2.log("   - factory.setRegistry(registry)");
        console2.log("2. Register adapters via timelock:");
        console2.log("   - registry.registerAdapter(erc4626Adapter)");
        console2.log("   - registry.registerAdapter(aaveV3Adapter)");
        console2.log("3. Set YieldSeeker server address");
        console2.log("4. Register target vaults/pools");
        console2.log("");
    }
}
