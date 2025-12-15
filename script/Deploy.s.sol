// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../src/ActionRegistry.sol";
import "../src/AdminTimelock.sol";
import "../src/AgentWallet.sol"; // Added for AgentWallet type
import "../src/AgentWalletFactory.sol";
import "../src/adapters/AaveV3Adapter.sol";
import "../src/adapters/ERC4626Adapter.sol";
import "../src/erc4337/IEntryPoint.sol";
import "forge-std/Script.sol";

/**
 * @title DeployScript
 * @notice Deploys the AgentWallet system with deterministic addresses.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast --verify
 *
 * SELECTIVE DEPLOYMENT:
 * To skip deploying a contract and use an existing address, uncomment the hardcoded address below.
 * This is useful for redeploying only specific contracts without touching others.
 */
contract DeployScript is Script {
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    // Change this if you want a fresh deployment at new addresses
    uint256 constant SALT = 0x123456789;

    // ============================================================
    // HARDCODED ADDRESSES (uncomment to skip deployment)
    // ============================================================
    // If you want to skip deploying a contract and use an existing one,
    // uncomment the line and set the address. The script will use this
    // address instead of deploying a new contract.

    // address constant HARDCODED_TIMELOCK = 0x...;
    // address constant HARDCODED_REGISTRY = 0x...;
    // address constant HARDCODED_FACTORY = 0x...;
    // address constant HARDCODED_IMPLEMENTATION = 0x...;
    // address constant HARDCODED_ERC4626_ADAPTER = 0x...;
    // address constant HARDCODED_AAVE_ADAPTER = 0x...;

    function run() public {
        // Read from DEPLOYER_PRIVATE_KEY environment variable
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=================================================");
        console.log("DEPLOYMENT SCRIPT");
        console.log("=================================================");
        console.log("Deploying with account:", deployer);
        console.log("Deployment Salt:", SALT);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AdminTimelock
        YieldSeekerAdminTimelock timelock;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     timelock = YieldSeekerAdminTimelock(payable(HARDCODED_TIMELOCK));
        //     console.log("Using existing AdminTimelock:", address(timelock));
        // } else {
        // NOTE(krishan711): change this before real deployment
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;
        timelock = new YieldSeekerAdminTimelock{salt: bytes32(SALT)}(proposers, executors, address(0));
        console.log("AdminTimelock deployed at:", address(timelock));
        // }

        // 2. Deploy or use hardcoded YieldSeekerAgentWalletFactory
        YieldSeekerAgentWalletFactory factory;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     factory = YieldSeekerAgentWalletFactory(HARDCODED_FACTORY);
        //     console.log("Using existing YieldSeekerAgentWalletFactory:", address(factory));
        // } else {
        factory = new YieldSeekerAgentWalletFactory{salt: bytes32(SALT)}(address(timelock), deployer);
        console.log("YieldSeekerAgentWalletFactory deployed at:", address(factory));
        // }

        // 3. Deploy or use hardcoded Implementation
        YieldSeekerAgentWallet implementation;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     implementation = YieldSeekerAgentWallet(payable(HARDCODED_IMPLEMENTATION));
        //     console.log("Using existing YieldSeekerAgentWallet Implementation:", address(implementation));
        // } else {
        implementation = new YieldSeekerAgentWallet{salt: bytes32(SALT)}(IEntryPoint(ENTRYPOINT), address(factory));
        console.log("YieldSeekerAgentWallet Implementation deployed at:", address(implementation));
        // }

        // 4. Deploy or use hardcoded ActionRegistry
        YieldSeekerActionRegistry registry;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     registry = YieldSeekerActionRegistry(HARDCODED_REGISTRY);
        //     console.log("Using existing YieldSeekerActionRegistry:", address(registry));
        // } else {
        registry = new YieldSeekerActionRegistry{salt: bytes32(SALT)}(address(timelock), deployer);
        console.log("YieldSeekerActionRegistry deployed at:", address(registry));
        // }

        // 5. Configure Factory (these operations require timelock, so we need to schedule them)
        // For initial deployment, we'll note that these need to be done via timelock
        console.log("");
        console.log("WARNING: Factory configuration requires timelock!");
        console.log("You must schedule and execute these operations through the timelock:");
        console.log("  - factory.setImplementation(implementation)");
        console.log("  - factory.setRegistry(registry)");
        console.log("See post-deployment instructions below.");
        console.log("");

        // 6. Deploy or use hardcoded Adapters
        YieldSeekerERC4626Adapter erc4626Adapter;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     erc4626Adapter = YieldSeekerERC4626Adapter(HARDCODED_ERC4626_ADAPTER);
        //     console.log("Using existing YieldSeekerERC4626Adapter:", address(erc4626Adapter));
        // } else {
        erc4626Adapter = new YieldSeekerERC4626Adapter{salt: bytes32(SALT)}();
        console.log("YieldSeekerERC4626Adapter deployed at:", address(erc4626Adapter));
        // }

        YieldSeekerAaveV3Adapter aaveV3Adapter;
        // if (false) { // Change to: if (true) to use hardcoded address
        //     aaveV3Adapter = YieldSeekerAaveV3Adapter(HARDCODED_AAVE_ADAPTER);
        //     console.log("Using existing YieldSeekerAaveV3Adapter:", address(aaveV3Adapter));
        // } else {
        aaveV3Adapter = new YieldSeekerAaveV3Adapter{salt: bytes32(SALT)}();
        console.log("YieldSeekerAaveV3Adapter deployed at:", address(aaveV3Adapter));
        // }

        console.log("");
        console.log("WARNING: Adapter registration requires timelock!");
        console.log("You must schedule and execute these operations through the timelock:");
        console.log("  - registry.registerAdapter(erc4626Adapter)");
        console.log("  - registry.registerAdapter(aaveV3Adapter)");
        console.log("See post-deployment instructions below.");
        console.log("");

        vm.stopBroadcast();

        console.log("");
        console.log("=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("AdminTimelock:          ", address(timelock));
        console.log("YieldSeekerAgentWalletFactory:     ", address(factory));
        console.log("ActionRegistry:         ", address(registry));
        console.log("AgentWallet Impl:       ", address(implementation));
        console.log("YieldSeekerERC4626Adapter:         ", address(erc4626Adapter));
        console.log("YieldSeekerAaveV3Adapter:          ", address(aaveV3Adapter));
        console.log("=================================================");
        console.log("");
        console.log("IMPORTANT: Post-Deployment Configuration (via Timelock)");
        console.log("All admin operations now require timelock (24h delay).");
        console.log("");
        console.log("Step 1: Configure Factory (via timelock schedule + execute):");
        console.log("  Schedule:");
        console.log("    cast send", address(timelock), "\"schedule(address,uint256,bytes,bytes32,bytes32,uint256)\"");
        console.log("      ", address(factory), "0");
        console.log("      \"$(cast calldata 'setImplementation(address)'", address(implementation), ")\" 0x0 0x0 86400");
        console.log("  Wait 24 hours, then execute:");
        console.log("    cast send", address(timelock), "\"execute(address,uint256,bytes,bytes32,bytes32)\"");
        console.log("      ", address(factory), "0");
        console.log("      \"$(cast calldata 'setImplementation(address)'", address(implementation), ")\" 0x0 0x0");
        console.log("");
        console.log("Step 2: Register Adapters (via timelock, similar process)");
        console.log("Step 3: Set YieldSeeker server address (via timelock)");
        console.log("Step 4: Register target vaults/pools (via timelock)");
        console.log("");

        // Export deployments to JSON for backend usage
        exportDeployments(
            address(timelock),
            address(factory),
            address(registry),
            address(implementation),
            address(erc4626Adapter),
            address(aaveV3Adapter)
        );
    }

    function exportDeployments(
        address timelock,
        address factory,
        address registry,
        address impl,
        address erc4626Adapter,
        address aaveV3Adapter
    )
        internal
    {
        string memory json = "json";
        vm.serializeAddress(json, "AdminTimelock", timelock);
        vm.serializeAddress(json, "YieldSeekerAgentWalletFactory", factory);
        vm.serializeAddress(json, "ActionRegistry", registry);
        vm.serializeAddress(json, "AgentWalletImplementation", impl);
        vm.serializeAddress(json, "YieldSeekerERC4626Adapter", erc4626Adapter);
        string memory finalJson = vm.serializeAddress(json, "YieldSeekerAaveV3Adapter", aaveV3Adapter);

        vm.writeJson(finalJson, "./deployments.json");
        console.log("Deployments exported to ./deployments.json");
    }
}
