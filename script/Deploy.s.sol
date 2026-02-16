// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../src/adapters/AerodromeCLSwapAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DeployScript
 * @notice Deploys the YieldSeeker AgentWallet system with selective contract deployment.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast
 */
contract DeployScript is Script {
    using stdJson for string;
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 constant SALT = 0x7;

    // Testing Mode: Set to true to deploy with 0-delay adminTimelock for faster testing
    // Set to false for production (uses 72-hour delay)
    bool constant TESTING_MODE = true;


    // State tracking
    struct Deployments {
        address adminTimelock;
        address agentWalletFactory;
        address adapterRegistry;
        address agentWalletImplementation;
        address feeTracker;
        address erc4626Adapter;
        address merklAdapter;
        address swapSellPolicy;
        address uniswapV3SwapAdapter;
        address aerodromeV2SwapAdapter;
        address aerodromeClSwapAdapter;
        address aaveV3Adapter;
        address compoundV3Adapter;
        address compoundV2Adapter;
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

    function getUniswapV3Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0x2626664c2603336E57B271c5C0b26F421741e481;
        }
        revert(string.concat("Unsupported chain id for Uniswap V3 router: ", vm.toString(chainId)));
    }

    function getAerodromeV2Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
        }
        revert(string.concat("Unsupported chain id for Aerodrome V2 router: ", vm.toString(chainId)));
    }

    function getAerodromeV2Factory(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
        }
        revert(string.concat("Unsupported chain id for Aerodrome V2 factory: ", vm.toString(chainId)));
    }

    function getAerodromeClRouter(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
        }
        revert(string.concat("Unsupported chain id for Aerodrome CL router: ", vm.toString(chainId)));
    }

    function run() public {
        address serverAddress = vm.envAddress("SERVER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address uniswapV3Router = getUniswapV3Router(block.chainid);
        address aerodromeV2Router = getAerodromeV2Router(block.chainid);
        address aerodromeV2Factory = getAerodromeV2Factory(block.chainid);
        address aerodromeClRouter = getAerodromeClRouter(block.chainid);

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
                merklAdapter: safeReadAddress(deployJson, ".merklAdapter"),
                swapSellPolicy: safeReadAddress(deployJson, ".swapSellPolicy"),
                uniswapV3SwapAdapter: safeReadAddress(deployJson, ".uniswapV3SwapAdapter"),
                aerodromeV2SwapAdapter: safeReadAddress(deployJson, ".aerodromeV2SwapAdapter"),
                aerodromeClSwapAdapter: safeReadAddress(deployJson, ".aerodromeCLSwapAdapter"),
                aaveV3Adapter: safeReadAddress(deployJson, ".aaveV3Adapter"),
                compoundV3Adapter: safeReadAddress(deployJson, ".compoundV3Adapter"),
                compoundV2Adapter: safeReadAddress(deployJson, ".compoundV2Adapter")
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

        // Deploy or reuse ERC4626 Adapter
        if (deployments.erc4626Adapter == address(0)) {
            ERC4626Adapter erc4626Adapter = new ERC4626Adapter{salt: bytes32(SALT)}();
            deployments.erc4626Adapter = address(erc4626Adapter);
            console2.log("-> ERC4626Adapter deployed at:", address(erc4626Adapter));
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        // Deploy or reuse Merkl Adapter
        if (deployments.merklAdapter == address(0)) {
            MerklAdapter merklAdapter = new MerklAdapter{salt: bytes32(SALT)}();
            deployments.merklAdapter = address(merklAdapter);
            console2.log("-> MerklAdapter deployed at:", address(merklAdapter));
        } else {
            console2.log("-> Using existing merklAdapter:", deployments.merklAdapter);
        }

        if (deployments.swapSellPolicy == address(0)) {
            SwapSellPolicy swapSellPolicy = new SwapSellPolicy{salt: bytes32(SALT)}(deployments.adminTimelock, deployerAddress, false);
            deployments.swapSellPolicy = address(swapSellPolicy);
            console2.log("-> SwapSellPolicy deployed at:", address(swapSellPolicy));
        } else {
            console2.log("-> Using existing swapSellPolicy:", deployments.swapSellPolicy);
        }

        if (deployments.uniswapV3SwapAdapter == address(0)) {
            UniswapV3SwapAdapter uniswapV3SwapAdapter = new UniswapV3SwapAdapter{salt: bytes32(SALT)}(uniswapV3Router, deployments.swapSellPolicy);
            deployments.uniswapV3SwapAdapter = address(uniswapV3SwapAdapter);
            console2.log("-> UniswapV3SwapAdapter deployed at:", address(uniswapV3SwapAdapter));
        } else {
            console2.log("-> Using existing uniswapV3SwapAdapter:", deployments.uniswapV3SwapAdapter);
        }

        if (deployments.aerodromeV2SwapAdapter == address(0)) {
            AerodromeV2SwapAdapter aerodromeV2SwapAdapter = new AerodromeV2SwapAdapter{salt: bytes32(SALT)}(aerodromeV2Router, aerodromeV2Factory, deployments.swapSellPolicy);
            deployments.aerodromeV2SwapAdapter = address(aerodromeV2SwapAdapter);
            console2.log("-> AerodromeV2SwapAdapter deployed at:", address(aerodromeV2SwapAdapter));
        } else {
            console2.log("-> Using existing aerodromeV2SwapAdapter:", deployments.aerodromeV2SwapAdapter);
        }

        if (deployments.aerodromeClSwapAdapter == address(0)) {
            AerodromeCLSwapAdapter aerodromeClSwapAdapter = new AerodromeCLSwapAdapter{salt: bytes32(SALT)}(aerodromeClRouter, deployments.swapSellPolicy);
            deployments.aerodromeClSwapAdapter = address(aerodromeClSwapAdapter);
            console2.log("-> AerodromeCLSwapAdapter deployed at:", address(aerodromeClSwapAdapter));
        } else {
            console2.log("-> Using existing aerodromeCLSwapAdapter:", deployments.aerodromeClSwapAdapter);
        }

        // Deploy or reuse Aave V3 Adapter
        if (deployments.aaveV3Adapter == address(0)) {
            AaveV3Adapter aaveV3Adapter = new AaveV3Adapter{salt: bytes32(SALT)}();
            deployments.aaveV3Adapter = address(aaveV3Adapter);
            console2.log("-> AaveV3Adapter deployed at:", address(aaveV3Adapter));
        } else {
            console2.log("-> Using existing aaveV3Adapter:", deployments.aaveV3Adapter);
        }

        // Deploy or reuse Compound V3 Adapter
        if (deployments.compoundV3Adapter == address(0)) {
            CompoundV3Adapter compoundV3Adapter = new CompoundV3Adapter{salt: bytes32(SALT)}();
            deployments.compoundV3Adapter = address(compoundV3Adapter);
            console2.log("-> CompoundV3Adapter deployed at:", address(compoundV3Adapter));
        } else {
            console2.log("-> Using existing compoundV3Adapter:", deployments.compoundV3Adapter);
        }

        // Deploy or reuse Compound V2 Adapter (for Moonwell and other Compound V2 forks)
        if (deployments.compoundV2Adapter == address(0)) {
            CompoundV2Adapter compoundV2Adapter = new CompoundV2Adapter{salt: bytes32(SALT)}();
            deployments.compoundV2Adapter = address(compoundV2Adapter);
            console2.log("-> CompoundV2Adapter deployed at:", address(compoundV2Adapter));
        } else {
            console2.log("-> Using existing compoundV2Adapter:", deployments.compoundV2Adapter);
        }

        // Export deployments to JSON
        string memory json = "json";
        vm.serializeAddress(json, "adminTimelock", deployments.adminTimelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.agentWalletFactory);
        vm.serializeAddress(json, "adapterRegistry", deployments.adapterRegistry);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.agentWalletImplementation);
        vm.serializeAddress(json, "feeTracker", deployments.feeTracker);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        vm.serializeAddress(json, "merklAdapter", deployments.merklAdapter);
        vm.serializeAddress(json, "swapSellPolicy", deployments.swapSellPolicy);
        vm.serializeAddress(json, "uniswapV3SwapAdapter", deployments.uniswapV3SwapAdapter);
        vm.serializeAddress(json, "aerodromeV2SwapAdapter", deployments.aerodromeV2SwapAdapter);
        vm.serializeAddress(json, "aerodromeCLSwapAdapter", deployments.aerodromeClSwapAdapter);
        vm.serializeAddress(json, "aaveV3Adapter", deployments.aaveV3Adapter);
        vm.serializeAddress(json, "compoundV3Adapter", deployments.compoundV3Adapter);
        string memory finalJson = vm.serializeAddress(json, "compoundV2Adapter", deployments.compoundV2Adapter);
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

        address[] memory targets = new address[](13);
        bytes[] memory datas = new bytes[](13);
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
        if (!adapterRegistry.isRegisteredAdapter(deployments.merklAdapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.merklAdapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.uniswapV3SwapAdapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.uniswapV3SwapAdapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.aerodromeV2SwapAdapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.aerodromeV2SwapAdapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.aerodromeClSwapAdapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.aerodromeClSwapAdapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.aaveV3Adapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.aaveV3Adapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.compoundV3Adapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.compoundV3Adapter));
            operationCount++;
        }
        if (!adapterRegistry.isRegisteredAdapter(deployments.compoundV2Adapter)) {
            targets[operationCount] = deployments.adapterRegistry;
            datas[operationCount] = abi.encodeCall(adapterRegistry.registerAdapter, (deployments.compoundV2Adapter));
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
