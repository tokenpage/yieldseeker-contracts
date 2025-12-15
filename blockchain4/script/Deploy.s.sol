// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/ActionRegistry.sol";
import "../src/AgentWalletFactory.sol";
import "../src/adapters/AaveV3Adapter.sol";
import "../src/adapters/ERC4626Adapter.sol";
import "../src/erc4337/IEntryPoint.sol";

/**
 * @title DeployScript
 * @notice Deploys the AgentWallet system with deterministic addresses.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast --verify
 */
contract DeployScript is Script {
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    // Change this if you want a fresh deployment at new addresses
    uint256 constant SALT = 0x123456789;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying with account:", deployer);
        console.log("Deployment Salt:", SALT);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ActionRegistry (Deterministic)
        // Note: Address depends on (Deployer, Salt, Bytecode, ConstructorArgs)
        ActionRegistry registry = new ActionRegistry{salt: bytes32(SALT)}(deployer);
        console.log("ActionRegistry deployed at:", address(registry));

        // 2. Deploy AgentWalletFactory (Deterministic)
        // Note: Constructor now only takes admin, so address is independent of Registry/EntryPoint
        AgentWalletFactory factory = new AgentWalletFactory{salt: bytes32(SALT)}(deployer);
        console.log("AgentWalletFactory deployed at:", address(factory));

        // 3. Deploy Implementation and Configure Factory
        AgentWallet implementation = new AgentWallet{salt: bytes32(SALT)}(
            IEntryPoint(ENTRYPOINT),
            address(factory)
        );
        console.log("AgentWallet Implementation deployed at:", address(implementation));

        if (address(factory.accountImplementation()) != address(implementation)) {
            factory.setImplementation(implementation);
            console.log("Factory implementation set");
        }

        if (address(factory.actionRegistry()) != address(registry)) {
            factory.setRegistry(registry);
            console.log("Factory registry set");
        }

        // 3. Deploy Adapters (using deterministic address based on bytecode - registry usage removed)
        ERC4626Adapter erc4626Adapter = new ERC4626Adapter{salt: bytes32(SALT)}();
        AaveV3Adapter aaveV3Adapter = new AaveV3Adapter{salt: bytes32(SALT)}();

        console.log("ERC4626Adapter Deployed at:", address(erc4626Adapter));
        console.log("AaveV3Adapter Deployed at:", address(aaveV3Adapter));

        // 4. Register Adapters
        if (!registry.isRegisteredAdapter(address(erc4626Adapter))) {
            registry.registerAdapter(address(erc4626Adapter));
        }
        if (!registry.isRegisteredAdapter(address(aaveV3Adapter))) {
            registry.registerAdapter(address(aaveV3Adapter));
        }

        if (!registry.isRegisteredAdapter(address(erc4626Adapter))) {
            registry.registerAdapter(address(erc4626Adapter));
             console.log("Registered ERC4626Adapter");
        } else {
             console.log("ERC4626Adapter already registered");
        }

        vm.stopBroadcast();

        console.log("Deployment Complete.");
        console.log("--------------------------------------------------");
        console.log("AgentWalletFactory:", address(factory));
        console.log("ActionRegistry:", address(registry));
        console.log("--------------------------------------------------");

        // Export deployments to JSON for backend usage
        exportDeployments(address(factory), address(registry), address(implementation));
    }

    function exportDeployments(address factory, address registry, address impl) internal {
        string memory json = "json";
        vm.serializeAddress(json, "AgentWalletFactory", factory);
        vm.serializeAddress(json, "ActionRegistry", registry);
        string memory finalJson = vm.serializeAddress(json, "AgentWalletImplementation", impl);

        vm.writeJson(finalJson, "./deployments.json");
        console.log("Deployments exported to ./deployments.json");
    }
}
