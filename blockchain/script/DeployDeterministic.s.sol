// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAccessController} from "../src/AccessController.sol";

/**
 * @title DeployDeterministic
 * @notice Deploys all contracts with deterministic addresses using CREATE2
 * @dev Uses Safe Singleton Factory (0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7)
 *      Available on 100+ chains: https://github.com/safe-global/safe-singleton-factory
 *
 * CRITICAL: Deploy in this exact order on ALL chains:
 * 1. AccessController (includes vault & swap registry)
 * 2. AgentWallet (implementation)
 * 3. AgentWalletFactory
 *
 * Usage:
 *   forge script script/DeployDeterministic.s.sol:DeployDeterministic \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployDeterministic is Script {
    // Safe Singleton Factory - deployed on most EVM chains
    address constant SAFE_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

    // Deterministic salts - NEVER change these after first deployment
    bytes32 constant ACCESS_CONTROLLER_SALT = keccak256("YieldSeeker.AccessController.v1");
    bytes32 constant AGENT_WALLET_SALT = keccak256("YieldSeeker.AgentWallet.v1");
    bytes32 constant FACTORY_SALT = keccak256("YieldSeeker.AgentWalletFactory.v1");

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Deploying with Safe Singleton Factory:", SAFE_FACTORY);
        console.log("Deployer:", deployer);
        console.log("---");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AccessController (includes vault & swap registry)
        address accessController = deployDeterministic(
            ACCESS_CONTROLLER_SALT,
            type(YieldSeekerAccessController).creationCode,
            abi.encode(deployer) // admin
        );
        console.log("AccessController deployed at:", accessController);

        // 2. Deploy AgentWallet (implementation)
        address agentWallet = deployDeterministic(
            AGENT_WALLET_SALT,
            type(YieldSeekerAgentWallet).creationCode,
            abi.encode(accessController)
        );
        console.log("AgentWallet deployed at:", agentWallet);

        // 3. Deploy AgentWalletFactory
        address factory = deployDeterministic(
            FACTORY_SALT,
            type(YieldSeekerAgentWalletFactory).creationCode,
            abi.encode(deployer, agentWallet)
        );
        console.log("AgentWalletFactory deployed at:", factory);

        vm.stopBroadcast();

        console.log("---");
        console.log("Deployment complete!");
        console.log("ALL addresses will be IDENTICAL on every chain");
        console.log("---");
        console.log("Next steps:");
        console.log("1. Add backend operator EOAs to AccessController (grantRole OPERATOR_ROLE)");
        console.log("2. Approve vault providers in AccessController (approveVaultProvider)");
        console.log("3. Register vaults with providers (registerVault)");
        console.log("4. Approve swap providers in AccessController (approveSwapProvider)");
    }

    /**
     * @notice Deploy contract using Safe Singleton Factory (CREATE2)
     * @param salt Deterministic salt
     * @param creationCode Contract creation bytecode
     * @param constructorArgs ABI-encoded constructor arguments
     * @return deployed Address of deployed contract
     */
    function deployDeterministic(bytes32 salt, bytes memory creationCode, bytes memory constructorArgs) internal returns (address deployed) {
        bytes memory initCode = abi.encodePacked(creationCode, constructorArgs);

        // Predict address
        deployed = predictAddress(salt, initCode);

        // Check if already deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(deployed)
        }

        if (codeSize > 0) {
            console.log("Contract already deployed at:", deployed);
            return deployed;
        }

        // Deploy via Safe Singleton Factory
        (bool success, bytes memory returnData) = SAFE_FACTORY.call(abi.encodePacked(salt, initCode));

        require(success, "Deployment failed");

        // Safe Factory returns deployed address
        deployed = abi.decode(returnData, (address));

        return deployed;
    }

    /**
     * @notice Predict contract address before deployment
     * @param salt Deterministic salt
     * @param initCode Contract init code (creation code + constructor args)
     * @return predicted Predicted contract address
     */
    function predictAddress(bytes32 salt, bytes memory initCode) internal pure returns (address predicted) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), SAFE_FACTORY, salt, keccak256(initCode)));

        return address(uint160(uint256(hash)));
    }
}
