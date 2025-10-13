// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {YieldSeekerAccessController} from "../src/AccessController.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";

/**
 * @title Deploy
 * @notice Deployment script for YieldSeeker v2 system
 */
contract Deploy is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);

        vm.startBroadcast(deployer);

        // 1. Deploy AccessController
        console2.log("\n1. Deploying AccessController...");
        YieldSeekerAccessController accessController = new YieldSeekerAccessController(admin);
        console2.log("AccessController deployed at:", address(accessController));

        // 2. Deploy AgentWallet Implementation
        console2.log("\n2. Deploying AgentWallet implementation...");
        YieldSeekerAgentWallet agentWalletImpl = new YieldSeekerAgentWallet(address(accessController));
        console2.log("AgentWallet implementation deployed at:", address(agentWalletImpl));

        // 3. Deploy AgentWalletFactory
        console2.log("\n3. Deploying AgentWalletFactory...");
        YieldSeekerAgentWalletFactory factory = new YieldSeekerAgentWalletFactory(admin, address(agentWalletImpl));
        console2.log("AgentWalletFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Print summary
        console2.log("\n=== Deployment Summary ===");
        console2.log("AccessController:", address(accessController));
        console2.log("AgentWallet Implementation:", address(agentWalletImpl));
        console2.log("AgentWalletFactory:", address(factory));
        console2.log("\nNext steps:");
        console2.log("1. Grant OPERATOR_ROLE to backend operator");
        console2.log("2. Approve vault contracts in AccessController");
        console2.log("3. Approve swap provider contracts in AccessController");
    }
}
