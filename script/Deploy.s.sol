// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../src/AgentWalletV3.sol";
import {YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerAaveV3LendingAdapter as AaveV3LendingAdapter} from "../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../src/adapters/AaveV4LendingAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerAgentTransferAdapter as AgentTransferAdapter} from "../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {YieldSeekerMoonwellRewardAdapter as MoonwellRewardAdapter} from "../src/adapters/MoonwellRewardAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter as MorphoBlueLendingAdapter} from "../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule as BorrowFeeModule} from "../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule as YieldFeeModule} from "../src/fees/YieldFeeModule.sol";
import {YieldSeekerBorrowSwapPolicy as BorrowSwapPolicy} from "../src/swaps/BorrowSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy as VaultSwapPolicy} from "../src/swaps/VaultSwapPolicy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title DeployScript
 * @notice Deploys the YieldSeeker AgentWallet system with selective contract deployment.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast
 *      The V2 system (factory, fee tracker, vault registry and its adapters) stays live for V2 wallets and is kept in
 *      deployments.json under agentWalletV2* keys; this script never deploys or configures it, except to grant the
 *      V2 vault registry's EMERGENCY_ROLE to KRISHAN711_ETH. Vaults and reward targets in both vault registries, price
 *      sources, borrow markets and sellable tokens come from script/config/base.json through Configure.s.sol; this
 *      script sets only the targets it deploys adapters for (CL2/CL3/CL4 routers, agent transfers, the borrow
 *      registry's routers and Merkl).
 */
contract DeployScript is Script {
    using stdJson for string;
    // Deployment Salt for deterministic addresses
    uint256 constant SALT = 0x711;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // The Safe in the factory's constructor: it fixes the factory's address, and so every wallet address, on every
    // chain; recreate it on a new chain from its original setup (README, "The Safe's original setup")
    address constant FACTORY_ROOT_SAFE = 0x403EE3392A40D017a009384D1bE1a2Ca921C2fEa;
    // krishan711.eth: a second emergency admin next to the deployer, so pausing and operator removal don't depend on
    // the hot deployer key alone
    address constant KRISHAN711_ETH = 0xcec34E6E3babc36Ef72e31bd5808B87214F4A3A8;
    bytes32 constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Testing Mode: Set to true to deploy with 0-delay adminTimelock for faster testing
    // Set to false for production (uses 4-day delay)
    bool constant TESTING_MODE = false;

    bytes32 constant VAULT_AGENT_PROFILE = keccak256("vault");
    bytes32 constant BORROW_AGENT_PROFILE = keccak256("borrow");
    uint256 constant YIELD_MAX_FEE_BPS = 5000;
    uint256 constant YIELD_DEFAULT_FEE_BPS = 1000;
    uint256 constant BORROW_MAX_FEE_BPS = 200;
    uint256 constant BORROW_DEFAULT_FEE_BPS = 50;
    uint256 constant BORROW_SWAP_MAX_SLIPPAGE_BPS = 100;

    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // State tracking
    struct Deployments {
        address adminTimelock;
        address agentWalletFactory;
        address agentWalletImplementation;
        address vaultFeeTracker;
        address borrowFeeTracker;
        address vaultYieldFeeModule;
        address borrowYieldFeeModule;
        address borrowFeeModule;
        address priceOracle;
        address swapSellPolicy;
        address vaultSwapPolicy;
        address borrowSwapPolicy;
        address vaultAdapterRegistry;
        address borrowAdapterRegistry;
        address erc4626Adapter;
        address aaveV3Adapter;
        address compoundV3Adapter;
        address compoundV2Adapter;
        address moonwellRewardAdapter;
        address merklAdapter;
        address uniswapV3SwapAdapter;
        address aerodromeV2SwapAdapter;
        address aerodromeClSwapAdapter;
        address aerodromeCl2SwapAdapter;
        address aerodromeCl3SwapAdapter;
        address aerodromeCl4SwapAdapter;
        address aaveV3LendingAdapter;
        address aaveV4LendingAdapter;
        address morphoBlueLendingAdapter;
        address agentTransferAdapter;
    }

    /// @dev V2-system entries kept in deployments.json as they are; never deployed or configured by this script, except
    ///      for granting the V2 vault registry's EMERGENCY_ROLE to KRISHAN711_ETH
    string[14] internal LEGACY_KEYS = [
        "agentWalletV1Implementation",
        "agentWalletV2Implementation",
        "agentWalletV2Factory",
        "agentWalletV2FeeTracker",
        "agentWalletV2AdapterRegistry",
        "agentWalletV2Erc4626Adapter",
        "agentWalletV2AaveV3Adapter",
        "agentWalletV2CompoundV3Adapter",
        "agentWalletV2CompoundV2Adapter",
        "agentWalletV2MoonwellRewardAdapter",
        "agentWalletV2MerklAdapter",
        "agentWalletV2UniswapV3SwapAdapter",
        "agentWalletV2AerodromeV2SwapAdapter",
        "agentWalletV2AerodromeCLSwapAdapter"
    ];

    address[] internal _targets;
    bytes[] internal _datas;

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

    /// @dev A failed or simulated run can leave an address with no code in deployments.json; it counts as not deployed
    function _readDeployed(string memory json, string memory key) internal view returns (address deployed) {
        deployed = safeReadAddress(json, key);
        if (deployed.code.length == 0) return address(0);
    }

    function deployCreate2(bytes memory initCode) internal returns (address deployed) {
        return deployCreate2(initCode, bytes32(SALT));
    }

    /// @dev Init code includes the constructor arguments, so code already at the predicted address is this exact contract
    ///      with the same constructor-assigned roles (for example deployed there by someone else); it is reused
    function deployCreate2(bytes memory initCode, bytes32 salt) internal returns (address deployed) {
        require(CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer has no code");
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode))))));
        if (predicted.code.length > 0) {
            console2.log("   (already deployed with this init code, reusing)", predicted);
            return predicted;
        }
        (bool success, bytes memory returnData) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(success, "CREATE2 deployment failed");
        require(returnData.length == 20, "CREATE2 deployer returned invalid address");
        assembly ("memory-safe") {
            deployed := shr(96, mload(add(returnData, 32)))
        }
        require(deployed == predicted, "CREATE2 address mismatch");
        require(deployed.code.length > 0, "CREATE2 deployment produced no code");
    }

    /// @dev The factory is created with the Safe in every role, so its CREATE2 address, and with it every wallet's
    ///      address, depends only on the Safe and the factory bytecode. The Safe can be recreated at the same address on
    ///      any chain, so no single key is needed to deploy there. The Safe then hands the admin role to this chain's
    ///      timelock, the operator role to the server and the emergency role to the emergency admin, and gives up all
    ///      three; ./script/check-timelock.sh bundles these calls for the Safe. Returns no calls once that is done.
    function _factoryHandoverCalls(AgentWalletFactory factory, address safe, address timelock, address emergencyAdmin, address server) internal view returns (bytes[] memory calls) {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        if (!factory.hasRole(adminRole, safe)) return new bytes[](0);
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        bytes32 emergencyRole = factory.EMERGENCY_ROLE();
        bytes[] memory all = new bytes[](6);
        uint256 count;
        all[count++] = abi.encodeCall(factory.grantRole, (adminRole, timelock));
        all[count++] = abi.encodeCall(factory.grantRole, (operatorRole, server));
        all[count++] = abi.encodeCall(factory.grantRole, (emergencyRole, emergencyAdmin));
        if (safe != server) all[count++] = abi.encodeCall(factory.revokeRole, (operatorRole, safe));
        if (safe != emergencyAdmin) all[count++] = abi.encodeCall(factory.revokeRole, (emergencyRole, safe));
        all[count++] = abi.encodeCall(factory.renounceRole, (adminRole, safe));
        calls = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            calls[i] = all[i];
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

    function getAerodromeCl2Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;
        }
        revert(string.concat("Unsupported chain id for Aerodrome CL2 router: ", vm.toString(chainId)));
    }

    function getAerodromeCl3Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
        }
        revert(string.concat("Unsupported chain id for Aerodrome CL3 router: ", vm.toString(chainId)));
    }

    /// @dev The Slipstream router of factory 0x9CB220581b91b0C83223012FE69688b92aD07a76, which held the deepest
    ///      tokenized-stock pools on Base in November 2026
    function getAerodromeCl4Router(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0x9Ee35Bf1bd69a03c6F0393582030fCe8Bb93D418;
        }
        revert(string.concat("Unsupported chain id for Aerodrome CL4 router: ", vm.toString(chainId)));
    }

    function getWellToken(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0xA88594D404727625A9437C3f886C7643872296AE;
        }
        revert(string.concat("Unsupported chain id for WELL token: ", vm.toString(chainId)));
    }

    function run() public {
        address serverAddress = vm.envAddress("SERVER_ADDRESS");
        address feeCollectorAddress = vm.envAddress("FEE_COLLECTOR_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address configuredMultisigAdminAddress = vm.envAddress("MULTISIG_ADMIN_ADDRESS");
        address multisigAdminAddress = TESTING_MODE ? deployerAddress : configuredMultisigAdminAddress;
        address timelockExecutorAddress = TESTING_MODE ? deployerAddress : multisigAdminAddress;
        address timelockAdminAddress = TESTING_MODE ? deployerAddress : multisigAdminAddress;
        address emergencyAdminAddress = deployerAddress;
        address factoryRootSafe = TESTING_MODE ? deployerAddress : FACTORY_ROOT_SAFE;
        uint256 adminTimelockDelay = TESTING_MODE ? 0 : 4 days;
        address uniswapV3Router = getUniswapV3Router(block.chainid);
        address aerodromeV2Router = getAerodromeV2Router(block.chainid);
        address aerodromeV2Factory = getAerodromeV2Factory(block.chainid);
        address aerodromeClRouter = getAerodromeClRouter(block.chainid);
        address aerodromeCl2Router = getAerodromeCl2Router(block.chainid);
        address aerodromeCl3Router = getAerodromeCl3Router(block.chainid);
        address aerodromeCl4Router = getAerodromeCl4Router(block.chainid);

        console2.log("=================================================");
        console2.log("YIELDSEEKER DEPLOYMENT SCRIPT");
        console2.log("=================================================");
        console2.log("Deployer:", deployerAddress);
        console2.log("Multisig Admin:", multisigAdminAddress);
        console2.log("Factory Root Safe:", factoryRootSafe);
        console2.log("Server:", serverAddress);
        console2.log("Fee Collector:", feeCollectorAddress);
        console2.log("Timelock Proposers and Cancellers:", deployerAddress, multisigAdminAddress);
        console2.log("Timelock Executor:", timelockExecutorAddress);
        console2.log("Timelock Admin:", timelockAdminAddress);
        console2.log("Emergency Admins:", emergencyAdminAddress, KRISHAN711_ETH);
        console2.log("Timelock Delay:", adminTimelockDelay);
        console2.log("Testing Mode:", TESTING_MODE);
        console2.log("");

        // Load existing deployments from JSON
        Deployments memory deployments;
        string memory path = "./deployments.json";
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory deployJson = vm.exists(path) ? vm.readFile(path) : "{}";
        deployments = Deployments({
            adminTimelock: _readDeployed(deployJson, ".adminTimelock"),
            agentWalletFactory: _readDeployed(deployJson, ".agentWalletFactory"),
            agentWalletImplementation: _readDeployed(deployJson, ".agentWalletImplementation"),
            vaultFeeTracker: _readDeployed(deployJson, ".vaultFeeTracker"),
            borrowFeeTracker: _readDeployed(deployJson, ".borrowFeeTracker"),
            vaultYieldFeeModule: _readDeployed(deployJson, ".vaultYieldFeeModule"),
            borrowYieldFeeModule: _readDeployed(deployJson, ".borrowYieldFeeModule"),
            borrowFeeModule: _readDeployed(deployJson, ".borrowFeeModule"),
            priceOracle: _readDeployed(deployJson, ".priceOracle"),
            swapSellPolicy: _readDeployed(deployJson, ".swapSellPolicy"),
            vaultSwapPolicy: _readDeployed(deployJson, ".vaultSwapPolicy"),
            borrowSwapPolicy: _readDeployed(deployJson, ".borrowSwapPolicy"),
            vaultAdapterRegistry: _readDeployed(deployJson, ".vaultAdapterRegistry"),
            borrowAdapterRegistry: _readDeployed(deployJson, ".borrowAdapterRegistry"),
            erc4626Adapter: _readDeployed(deployJson, ".erc4626Adapter"),
            aaveV3Adapter: _readDeployed(deployJson, ".aaveV3Adapter"),
            compoundV3Adapter: _readDeployed(deployJson, ".compoundV3Adapter"),
            compoundV2Adapter: _readDeployed(deployJson, ".compoundV2Adapter"),
            moonwellRewardAdapter: _readDeployed(deployJson, ".moonwellRewardAdapter"),
            merklAdapter: _readDeployed(deployJson, ".merklAdapter"),
            uniswapV3SwapAdapter: _readDeployed(deployJson, ".uniswapV3SwapAdapter"),
            aerodromeV2SwapAdapter: _readDeployed(deployJson, ".aerodromeV2SwapAdapter"),
            aerodromeClSwapAdapter: _readDeployed(deployJson, ".aerodromeCLSwapAdapter"),
            aerodromeCl2SwapAdapter: _readDeployed(deployJson, ".aerodromeCL2SwapAdapter"),
            aerodromeCl3SwapAdapter: _readDeployed(deployJson, ".aerodromeCL3SwapAdapter"),
            aerodromeCl4SwapAdapter: _readDeployed(deployJson, ".aerodromeCL4SwapAdapter"),
            aaveV3LendingAdapter: _readDeployed(deployJson, ".aaveV3LendingAdapter"),
            aaveV4LendingAdapter: _readDeployed(deployJson, ".aaveV4LendingAdapter"),
            morphoBlueLendingAdapter: _readDeployed(deployJson, ".morphoBlueLendingAdapter"),
            agentTransferAdapter: _readDeployed(deployJson, ".agentTransferAdapter")
        });

        vm.startBroadcast(deployerPrivateKey);

        // Deploy or reuse AdminTimelock
        if (deployments.adminTimelock == address(0)) {
            address[] memory proposers = new address[](2);
            proposers[0] = deployerAddress;
            proposers[1] = multisigAdminAddress;
            address[] memory executors = new address[](1);
            executors[0] = timelockExecutorAddress;
            deployments.adminTimelock = deployCreate2(abi.encodePacked(type(AdminTimelock).creationCode, abi.encode(adminTimelockDelay, proposers, executors, timelockAdminAddress)));
            console2.log("-> AdminTimelock deployed at:", deployments.adminTimelock);
            console2.log("   delay (seconds):", adminTimelockDelay);
        } else {
            console2.log("-> Using existing adminTimelock:", deployments.adminTimelock);
        }

        // Deploy or reuse AgentWalletFactory: constructor arguments are chain-independent (see _factoryHandoverCalls)
        if (deployments.agentWalletFactory == address(0)) {
            deployments.agentWalletFactory = deployCreate2(abi.encodePacked(type(AgentWalletFactory).creationCode, abi.encode(factoryRootSafe, factoryRootSafe, factoryRootSafe)));
            console2.log("-> AgentWalletFactory deployed at:", deployments.agentWalletFactory);
        } else {
            console2.log("-> Using existing agentWalletFactory:", deployments.agentWalletFactory);
        }
        bytes[] memory factoryHandover = _factoryHandoverCalls(AgentWalletFactory(deployments.agentWalletFactory), factoryRootSafe, deployments.adminTimelock, emergencyAdminAddress, serverAddress);
        if (factoryHandover.length > 0 && factoryRootSafe == deployerAddress) {
            for (uint256 i; i < factoryHandover.length; ++i) {
                (bool success,) = deployments.agentWalletFactory.call(factoryHandover[i]);
                require(success, "Factory handover failed");
            }
            factoryHandover = new bytes[](0);
        } else if (factoryHandover.length > 0) {
            console2.log("-> The Safe still holds the factory roles. Before the timelock batch, the Safe must call the factory with (./script/check-timelock.sh bundles these):");
            for (uint256 i; i < factoryHandover.length; ++i) {
                console2.logBytes(factoryHandover[i]);
            }
        }

        // Deploy or reuse AgentWallet V3 implementation
        if (deployments.agentWalletImplementation == address(0) || address(AgentWallet(payable(deployments.agentWalletImplementation)).FACTORY()) != deployments.agentWalletFactory) {
            deployments.agentWalletImplementation = deployCreate2(abi.encodePacked(type(AgentWallet).creationCode, abi.encode(deployments.agentWalletFactory)));
            console2.log("-> AgentWallet Implementation deployed at:", deployments.agentWalletImplementation);
        } else {
            console2.log("-> Using existing agentWalletImplementation:", deployments.agentWalletImplementation);
        }

        // Adapter registries (own salts, one per agent profile)
        if (deployments.vaultAdapterRegistry == address(0)) {
            deployments.vaultAdapterRegistry = deployCreate2(abi.encodePacked(type(AdapterRegistry).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress)), keccak256(abi.encode(SALT, "vaultAdapterRegistry")));
            console2.log("-> Vault AdapterRegistry deployed at:", deployments.vaultAdapterRegistry);
        } else {
            console2.log("-> Using existing vaultAdapterRegistry:", deployments.vaultAdapterRegistry);
        }

        if (deployments.borrowAdapterRegistry == address(0)) {
            deployments.borrowAdapterRegistry = deployCreate2(abi.encodePacked(type(AdapterRegistry).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress)), keccak256(abi.encode(SALT, "borrowAdapterRegistry")));
            console2.log("-> Borrow AdapterRegistry deployed at:", deployments.borrowAdapterRegistry);
        } else {
            console2.log("-> Using existing borrowAdapterRegistry:", deployments.borrowAdapterRegistry);
        }

        // Fee trackers (one per agent profile, own salts: same init code) and their fee modules
        if (deployments.vaultFeeTracker == address(0)) {
            deployments.vaultFeeTracker = deployCreate2(abi.encodePacked(type(FeeTracker).creationCode, abi.encode(deployments.adminTimelock, feeCollectorAddress)), keccak256(abi.encode(SALT, "vaultFeeTracker")));
            console2.log("-> Vault FeeTracker deployed at:", deployments.vaultFeeTracker);
        } else {
            console2.log("-> Using existing vaultFeeTracker:", deployments.vaultFeeTracker);
        }

        if (deployments.borrowFeeTracker == address(0)) {
            deployments.borrowFeeTracker = deployCreate2(abi.encodePacked(type(FeeTracker).creationCode, abi.encode(deployments.adminTimelock, feeCollectorAddress)), keccak256(abi.encode(SALT, "borrowFeeTracker")));
            console2.log("-> Borrow FeeTracker deployed at:", deployments.borrowFeeTracker);
        } else {
            console2.log("-> Using existing borrowFeeTracker:", deployments.borrowFeeTracker);
        }

        if (deployments.priceOracle == address(0)) {
            deployments.priceOracle = deployCreate2(abi.encodePacked(type(PriceOracle).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress, SEQUENCER_UPTIME_FEED)));
            console2.log("-> PriceOracle deployed at:", deployments.priceOracle);
        } else {
            console2.log("-> Using existing priceOracle:", deployments.priceOracle);
        }

        if (deployments.vaultYieldFeeModule == address(0) || YieldFeeModule(deployments.vaultYieldFeeModule).FEE_TRACKER() != deployments.vaultFeeTracker) {
            deployments.vaultYieldFeeModule = deployCreate2(abi.encodePacked(type(YieldFeeModule).creationCode, abi.encode(FeeTracker(deployments.vaultFeeTracker), YIELD_MAX_FEE_BPS)));
            console2.log("-> Vault YieldFeeModule deployed at:", deployments.vaultYieldFeeModule);
        } else {
            console2.log("-> Using existing vaultYieldFeeModule:", deployments.vaultYieldFeeModule);
        }

        if (deployments.borrowYieldFeeModule == address(0) || YieldFeeModule(deployments.borrowYieldFeeModule).FEE_TRACKER() != deployments.borrowFeeTracker) {
            deployments.borrowYieldFeeModule = deployCreate2(abi.encodePacked(type(YieldFeeModule).creationCode, abi.encode(FeeTracker(deployments.borrowFeeTracker), YIELD_MAX_FEE_BPS)));
            console2.log("-> Borrow YieldFeeModule deployed at:", deployments.borrowYieldFeeModule);
        } else {
            console2.log("-> Using existing borrowYieldFeeModule:", deployments.borrowYieldFeeModule);
        }

        if (deployments.borrowFeeModule == address(0) || BorrowFeeModule(deployments.borrowFeeModule).FEE_TRACKER() != deployments.borrowFeeTracker) {
            deployments.borrowFeeModule = deployCreate2(abi.encodePacked(type(BorrowFeeModule).creationCode, abi.encode(FeeTracker(deployments.borrowFeeTracker), BORROW_MAX_FEE_BPS)));
            console2.log("-> BorrowFeeModule deployed at:", deployments.borrowFeeModule);
        } else {
            console2.log("-> Using existing borrowFeeModule:", deployments.borrowFeeModule);
        }

        if (deployments.swapSellPolicy == address(0)) {
            deployments.swapSellPolicy = deployCreate2(abi.encodePacked(type(SwapSellPolicy).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress, false)));
            console2.log("-> SwapSellPolicy deployed at:", deployments.swapSellPolicy);
        } else {
            console2.log("-> Using existing swapSellPolicy:", deployments.swapSellPolicy);
        }

        if (deployments.vaultSwapPolicy == address(0) || address(VaultSwapPolicy(deployments.vaultSwapPolicy).SELL_POLICY()) != deployments.swapSellPolicy) {
            deployments.vaultSwapPolicy = deployCreate2(abi.encodePacked(type(VaultSwapPolicy).creationCode, abi.encode(deployments.swapSellPolicy)));
            console2.log("-> VaultSwapPolicy deployed at:", deployments.vaultSwapPolicy);
        } else {
            console2.log("-> Using existing vaultSwapPolicy:", deployments.vaultSwapPolicy);
        }

        if (
            deployments.borrowSwapPolicy == address(0) || address(BorrowSwapPolicy(deployments.borrowSwapPolicy).SELL_POLICY()) != deployments.swapSellPolicy
                || address(BorrowSwapPolicy(deployments.borrowSwapPolicy).PRICE_ORACLE()) != deployments.priceOracle || BorrowSwapPolicy(deployments.borrowSwapPolicy).MAX_SLIPPAGE_BPS() != BORROW_SWAP_MAX_SLIPPAGE_BPS
        ) {
            deployments.borrowSwapPolicy = deployCreate2(abi.encodePacked(type(BorrowSwapPolicy).creationCode, abi.encode(deployments.swapSellPolicy, deployments.priceOracle, BORROW_SWAP_MAX_SLIPPAGE_BPS)));
            console2.log("-> BorrowSwapPolicy deployed at:", deployments.borrowSwapPolicy);
        } else {
            console2.log("-> Using existing borrowSwapPolicy:", deployments.borrowSwapPolicy);
        }

        // Vault adapters
        if (deployments.erc4626Adapter == address(0)) {
            deployments.erc4626Adapter = deployCreate2(abi.encodePacked(type(ERC4626Adapter).creationCode));
            console2.log("-> ERC4626Adapter deployed at:", deployments.erc4626Adapter);
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        if (deployments.aaveV3Adapter == address(0)) {
            deployments.aaveV3Adapter = deployCreate2(abi.encodePacked(type(AaveV3Adapter).creationCode));
            console2.log("-> AaveV3Adapter deployed at:", deployments.aaveV3Adapter);
        } else {
            console2.log("-> Using existing aaveV3Adapter:", deployments.aaveV3Adapter);
        }

        if (deployments.compoundV3Adapter == address(0)) {
            deployments.compoundV3Adapter = deployCreate2(abi.encodePacked(type(CompoundV3Adapter).creationCode));
            console2.log("-> CompoundV3Adapter deployed at:", deployments.compoundV3Adapter);
        } else {
            console2.log("-> Using existing compoundV3Adapter:", deployments.compoundV3Adapter);
        }

        // Compound V2 Adapter (for Moonwell and other Compound V2 forks)
        if (deployments.compoundV2Adapter == address(0)) {
            deployments.compoundV2Adapter = deployCreate2(abi.encodePacked(type(CompoundV2Adapter).creationCode));
            console2.log("-> CompoundV2Adapter deployed at:", deployments.compoundV2Adapter);
        } else {
            console2.log("-> Using existing compoundV2Adapter:", deployments.compoundV2Adapter);
        }

        if (deployments.moonwellRewardAdapter == address(0)) {
            deployments.moonwellRewardAdapter = deployCreate2(abi.encodePacked(type(MoonwellRewardAdapter).creationCode, abi.encode(getWellToken(block.chainid))));
            console2.log("-> MoonwellRewardAdapter deployed at:", deployments.moonwellRewardAdapter);
        } else {
            console2.log("-> Using existing moonwellRewardAdapter:", deployments.moonwellRewardAdapter);
        }

        if (deployments.merklAdapter == address(0)) {
            deployments.merklAdapter = deployCreate2(abi.encodePacked(type(MerklAdapter).creationCode));
            console2.log("-> MerklAdapter deployed at:", deployments.merklAdapter);
        } else {
            console2.log("-> Using existing merklAdapter:", deployments.merklAdapter);
        }

        // Swap adapters (one per DEX, shared by every agent type; the rules come from each agent type's swap policy)
        if (deployments.uniswapV3SwapAdapter == address(0)) {
            deployments.uniswapV3SwapAdapter = deployCreate2(abi.encodePacked(type(UniswapV3SwapAdapter).creationCode, abi.encode(uniswapV3Router)));
            console2.log("-> UniswapV3SwapAdapter deployed at:", deployments.uniswapV3SwapAdapter);
        } else {
            console2.log("-> Using existing uniswapV3SwapAdapter:", deployments.uniswapV3SwapAdapter);
        }

        if (deployments.aerodromeV2SwapAdapter == address(0)) {
            deployments.aerodromeV2SwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeV2SwapAdapter).creationCode, abi.encode(aerodromeV2Router, aerodromeV2Factory)));
            console2.log("-> AerodromeV2SwapAdapter deployed at:", deployments.aerodromeV2SwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeV2SwapAdapter:", deployments.aerodromeV2SwapAdapter);
        }

        if (deployments.aerodromeClSwapAdapter == address(0)) {
            deployments.aerodromeClSwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeCLSwapAdapter).creationCode, abi.encode(aerodromeClRouter)));
            console2.log("-> AerodromeCLSwapAdapter deployed at:", deployments.aerodromeClSwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCLSwapAdapter:", deployments.aerodromeClSwapAdapter);
        }
        if (deployments.aerodromeCl2SwapAdapter == address(0)) {
            deployments.aerodromeCl2SwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeCLSwapAdapter).creationCode, abi.encode(aerodromeCl2Router)));
            console2.log("-> AerodromeCL2SwapAdapter deployed at:", deployments.aerodromeCl2SwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCL2SwapAdapter:", deployments.aerodromeCl2SwapAdapter);
        }

        if (deployments.aerodromeCl3SwapAdapter == address(0)) {
            deployments.aerodromeCl3SwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeCLSwapAdapter).creationCode, abi.encode(aerodromeCl3Router)));
            console2.log("-> AerodromeCL3SwapAdapter deployed at:", deployments.aerodromeCl3SwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCL3SwapAdapter:", deployments.aerodromeCl3SwapAdapter);
        }

        if (deployments.aerodromeCl4SwapAdapter == address(0)) {
            deployments.aerodromeCl4SwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeCLSwapAdapter).creationCode, abi.encode(aerodromeCl4Router)));
            console2.log("-> AerodromeCL4SwapAdapter deployed at:", deployments.aerodromeCl4SwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCL4SwapAdapter:", deployments.aerodromeCl4SwapAdapter);
        }

        // Lending adapters
        if (deployments.aaveV3LendingAdapter == address(0)) {
            deployments.aaveV3LendingAdapter = deployCreate2(type(AaveV3LendingAdapter).creationCode);
            console2.log("-> AaveV3LendingAdapter deployed at:", deployments.aaveV3LendingAdapter);
        } else {
            console2.log("-> Using existing aaveV3LendingAdapter:", deployments.aaveV3LendingAdapter);
        }

        if (deployments.aaveV4LendingAdapter == address(0)) {
            deployments.aaveV4LendingAdapter = deployCreate2(type(AaveV4LendingAdapter).creationCode);
            console2.log("-> AaveV4LendingAdapter deployed at:", deployments.aaveV4LendingAdapter);
        } else {
            console2.log("-> Using existing aaveV4LendingAdapter:", deployments.aaveV4LendingAdapter);
        }

        if (deployments.morphoBlueLendingAdapter == address(0)) {
            deployments.morphoBlueLendingAdapter = deployCreate2(type(MorphoBlueLendingAdapter).creationCode);
            console2.log("-> MorphoBlueLendingAdapter deployed at:", deployments.morphoBlueLendingAdapter);
        } else {
            console2.log("-> Using existing morphoBlueLendingAdapter:", deployments.morphoBlueLendingAdapter);
        }

        if (deployments.agentTransferAdapter == address(0)) {
            deployments.agentTransferAdapter = deployCreate2(type(AgentTransferAdapter).creationCode);
            console2.log("-> AgentTransferAdapter deployed at:", deployments.agentTransferAdapter);
        } else {
            console2.log("-> Using existing agentTransferAdapter:", deployments.agentTransferAdapter);
        }

        // Export deployments to JSON
        string memory json = "json";
        for (uint256 i = 0; i < LEGACY_KEYS.length; i++) {
            address legacyAddress = safeReadAddress(deployJson, string.concat(".", LEGACY_KEYS[i]));
            if (legacyAddress != address(0)) vm.serializeAddress(json, LEGACY_KEYS[i], legacyAddress);
        }
        vm.serializeAddress(json, "adminTimelock", deployments.adminTimelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.agentWalletFactory);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.agentWalletImplementation);
        vm.serializeAddress(json, "vaultFeeTracker", deployments.vaultFeeTracker);
        vm.serializeAddress(json, "borrowFeeTracker", deployments.borrowFeeTracker);
        vm.serializeAddress(json, "vaultYieldFeeModule", deployments.vaultYieldFeeModule);
        vm.serializeAddress(json, "borrowYieldFeeModule", deployments.borrowYieldFeeModule);
        vm.serializeAddress(json, "borrowFeeModule", deployments.borrowFeeModule);
        vm.serializeAddress(json, "priceOracle", deployments.priceOracle);
        vm.serializeAddress(json, "swapSellPolicy", deployments.swapSellPolicy);
        vm.serializeAddress(json, "vaultSwapPolicy", deployments.vaultSwapPolicy);
        vm.serializeAddress(json, "borrowSwapPolicy", deployments.borrowSwapPolicy);
        vm.serializeAddress(json, "vaultAdapterRegistry", deployments.vaultAdapterRegistry);
        vm.serializeAddress(json, "borrowAdapterRegistry", deployments.borrowAdapterRegistry);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        vm.serializeAddress(json, "aaveV3Adapter", deployments.aaveV3Adapter);
        vm.serializeAddress(json, "compoundV3Adapter", deployments.compoundV3Adapter);
        vm.serializeAddress(json, "compoundV2Adapter", deployments.compoundV2Adapter);
        vm.serializeAddress(json, "moonwellRewardAdapter", deployments.moonwellRewardAdapter);
        vm.serializeAddress(json, "merklAdapter", deployments.merklAdapter);
        vm.serializeAddress(json, "uniswapV3SwapAdapter", deployments.uniswapV3SwapAdapter);
        vm.serializeAddress(json, "aerodromeV2SwapAdapter", deployments.aerodromeV2SwapAdapter);
        vm.serializeAddress(json, "aerodromeCLSwapAdapter", deployments.aerodromeClSwapAdapter);
        vm.serializeAddress(json, "aerodromeCL2SwapAdapter", deployments.aerodromeCl2SwapAdapter);
        vm.serializeAddress(json, "aerodromeCL3SwapAdapter", deployments.aerodromeCl3SwapAdapter);
        vm.serializeAddress(json, "aerodromeCL4SwapAdapter", deployments.aerodromeCl4SwapAdapter);
        vm.serializeAddress(json, "aaveV3LendingAdapter", deployments.aaveV3LendingAdapter);
        vm.serializeAddress(json, "aaveV4LendingAdapter", deployments.aaveV4LendingAdapter);
        vm.serializeAddress(json, "morphoBlueLendingAdapter", deployments.morphoBlueLendingAdapter);
        string memory finalJson = vm.serializeAddress(json, "agentTransferAdapter", deployments.agentTransferAdapter);
        vm.writeJson(finalJson, "./deployments.json");
        console2.log("-> Deployments saved to ./deployments.json");

        // Post-deployment configuration
        console2.log("");
        console2.log("=================================================");
        console2.log("POST-DEPLOYMENT CONFIGURATION");
        console2.log("=================================================");
        AdapterRegistry vaultAdapterRegistry = AdapterRegistry(deployments.vaultAdapterRegistry);
        AdapterRegistry borrowAdapterRegistry = AdapterRegistry(deployments.borrowAdapterRegistry);
        AgentWalletFactory agentWalletFactory = AgentWalletFactory(deployments.agentWalletFactory);
        FeeTracker vaultFeeTracker = FeeTracker(deployments.vaultFeeTracker);
        FeeTracker borrowFeeTracker = FeeTracker(deployments.borrowFeeTracker);
        AdminTimelock adminTimelock = AdminTimelock(payable(deployments.adminTimelock));
        uint256 timelockDelay = adminTimelock.getMinDelay();

        // 1. Configure Factory and FeeTrackers
        console2.log("-> Preparing agentWalletFactory configuration...");
        if (address(agentWalletFactory.agentWalletImplementation()) != deployments.agentWalletImplementation) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAgentWalletImplementation, (AgentWallet(payable(deployments.agentWalletImplementation)))));
        }
        _requireNotReplaced(address(agentWalletFactory.adapterRegistry(VAULT_AGENT_PROFILE)), address(vaultAdapterRegistry), "the vault adapter registry");
        _requireNotReplaced(address(agentWalletFactory.adapterRegistry(BORROW_AGENT_PROFILE)), address(borrowAdapterRegistry), "the borrow adapter registry");
        _requireNotReplaced(address(agentWalletFactory.feeTracker(VAULT_AGENT_PROFILE)), address(vaultFeeTracker), "the vault fee tracker");
        _requireNotReplaced(address(agentWalletFactory.feeTracker(BORROW_AGENT_PROFILE)), address(borrowFeeTracker), "the borrow fee tracker");
        _requireNotReplaced(address(borrowFeeTracker.feeModules(BORROW_FEE)), deployments.borrowFeeModule, "the borrow fee module");
        if (address(agentWalletFactory.adapterRegistry(VAULT_AGENT_PROFILE)) != address(vaultAdapterRegistry)) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAdapterRegistry, (VAULT_AGENT_PROFILE, vaultAdapterRegistry)));
        }
        if (address(agentWalletFactory.adapterRegistry(BORROW_AGENT_PROFILE)) != address(borrowAdapterRegistry)) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAdapterRegistry, (BORROW_AGENT_PROFILE, borrowAdapterRegistry)));
        }
        if (address(agentWalletFactory.feeTracker(VAULT_AGENT_PROFILE)) != address(vaultFeeTracker)) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setFeeTracker, (VAULT_AGENT_PROFILE, vaultFeeTracker)));
        }
        if (address(agentWalletFactory.feeTracker(BORROW_AGENT_PROFILE)) != address(borrowFeeTracker)) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setFeeTracker, (BORROW_AGENT_PROFILE, borrowFeeTracker)));
        }
        if (address(agentWalletFactory.swapPolicy(VAULT_AGENT_PROFILE)) != deployments.vaultSwapPolicy) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setSwapPolicy, (VAULT_AGENT_PROFILE, VaultSwapPolicy(deployments.vaultSwapPolicy))));
        }
        if (address(agentWalletFactory.swapPolicy(BORROW_AGENT_PROFILE)) != deployments.borrowSwapPolicy) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setSwapPolicy, (BORROW_AGENT_PROFILE, BorrowSwapPolicy(deployments.borrowSwapPolicy))));
        }
        _configureFeeTracker(vaultFeeTracker, deployments.agentWalletFactory, deployments.vaultYieldFeeModule);
        _configureFeeTracker(borrowFeeTracker, deployments.agentWalletFactory, deployments.borrowYieldFeeModule);
        if (vaultFeeTracker.feeCollector() != feeCollectorAddress) _op(deployments.vaultFeeTracker, abi.encodeCall(vaultFeeTracker.setFeeCollector, (feeCollectorAddress)));
        if (borrowFeeTracker.feeCollector() != feeCollectorAddress) _op(deployments.borrowFeeTracker, abi.encodeCall(borrowFeeTracker.setFeeCollector, (feeCollectorAddress)));
        if (address(borrowFeeTracker.feeModules(BORROW_FEE)) != deployments.borrowFeeModule) {
            _op(deployments.borrowFeeTracker, abi.encodeCall(borrowFeeTracker.setFeeModule, (BORROW_FEE, BorrowFeeModule(deployments.borrowFeeModule))));
        }
        if (borrowFeeTracker.planCount(BORROW_FEE) == 0) {
            _op(deployments.borrowFeeTracker, abi.encodeCall(borrowFeeTracker.createPlan, (BORROW_FEE, abi.encode(BorrowFeeModule.Plan({rateBps: BORROW_DEFAULT_FEE_BPS})))));
        }
        // 2. Register Adapters
        console2.log("-> Preparing adapter registration...");
        _registerAdapter(vaultAdapterRegistry, deployments.erc4626Adapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aaveV3Adapter);
        _registerAdapter(vaultAdapterRegistry, deployments.compoundV3Adapter);
        _registerAdapter(vaultAdapterRegistry, deployments.compoundV2Adapter);
        _registerAdapter(vaultAdapterRegistry, deployments.moonwellRewardAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.merklAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.uniswapV3SwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aerodromeV2SwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aerodromeClSwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aerodromeCl2SwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aerodromeCl3SwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.aerodromeCl4SwapAdapter);
        _registerAdapter(vaultAdapterRegistry, deployments.agentTransferAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aaveV3LendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aaveV4LendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.morphoBlueLendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.merklAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.uniswapV3SwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeV2SwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeClSwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.agentTransferAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeCl2SwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeCl3SwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeCl4SwapAdapter);
        // 3. Set Vault Registry Targets this script owns; Configure.s.sol sets vaults and the shared swap and reward targets
        _setTarget(vaultAdapterRegistry, aerodromeCl2Router, deployments.aerodromeCl2SwapAdapter);
        _setTarget(vaultAdapterRegistry, aerodromeCl3Router, deployments.aerodromeCl3SwapAdapter);
        _setTarget(vaultAdapterRegistry, aerodromeCl4Router, deployments.aerodromeCl4SwapAdapter);
        _setTarget(vaultAdapterRegistry, deployments.agentTransferAdapter, deployments.agentTransferAdapter);
        // 4. Set Borrow Registry Targets
        _setTarget(borrowAdapterRegistry, uniswapV3Router, deployments.uniswapV3SwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeV2Router, deployments.aerodromeV2SwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeClRouter, deployments.aerodromeClSwapAdapter);
        _setTarget(borrowAdapterRegistry, MERKL_DISTRIBUTOR, deployments.merklAdapter);
        _setTarget(borrowAdapterRegistry, deployments.agentTransferAdapter, deployments.agentTransferAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeCl2Router, deployments.aerodromeCl2SwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeCl3Router, deployments.aerodromeCl3SwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeCl4Router, deployments.aerodromeCl4SwapAdapter);
        // 5. Set Agent Operator
        if (factoryHandover.length > 0) {
            console2.log("-> Server gets AGENT_OPERATOR_ROLE in the Safe's factory handover");
        } else if (!agentWalletFactory.hasRole(agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)) {
            console2.log("-> Preparing AGENT_OPERATOR_ROLE grant for server:", serverAddress);
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.grantRole, (agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)));
        } else {
            console2.log("-> Server already has AGENT_OPERATOR_ROLE");
        }
        // 6. Second emergency admin; the factory grant runs after the Safe's handover, which check-timelock.sh bundles first
        _grantEmergencyRole(deployments.agentWalletFactory);
        _grantEmergencyRole(deployments.vaultAdapterRegistry);
        _grantEmergencyRole(deployments.borrowAdapterRegistry);
        _grantEmergencyRole(deployments.priceOracle);
        _grantEmergencyRole(deployments.swapSellPolicy);
        _grantEmergencyRole(safeReadAddress(deployJson, ".agentWalletV2AdapterRegistry"));
        // Execute batch if there are operations
        if (_targets.length > 0) {
            console2.log("-> Executing", _targets.length, "operations in batch...");
            scheduleAndExecuteBatch(adminTimelock, _targets, new uint256[](_targets.length), _datas, timelockDelay, keccak256(abi.encode("deploy-config", block.number)));
            console2.log("-> Configuration complete!");
        } else {
            console2.log("-> No configuration needed, all settings are up to date!");
        }
        console2.log("=================================================");
        console2.log("Next: Configure.s.sol (vaults, price sources, borrow markets, sellable tokens); pass this batch's ID as its predecessor while it is pending");
        console2.log("=================================================");
        vm.stopBroadcast();
    }

    function _op(address target, bytes memory data) internal {
        _targets.push(target);
        _datas.push(data);
    }

    /// @dev The settings every agent profile's tracker shares: the wallet factory and the yield fee with its plan 0
    function _configureFeeTracker(FeeTracker tracker, address agentWalletFactory, address yieldFeeModule) internal {
        _requireNotReplaced(address(tracker.feeModules(YIELD_FEE)), yieldFeeModule, "a yield fee module");
        if (tracker.walletFactory() != agentWalletFactory) _op(address(tracker), abi.encodeCall(tracker.setWalletFactory, (agentWalletFactory)));
        if (address(tracker.feeModules(YIELD_FEE)) != yieldFeeModule) _op(address(tracker), abi.encodeCall(tracker.setFeeModule, (YIELD_FEE, YieldFeeModule(yieldFeeModule))));
        if (tracker.planCount(YIELD_FEE) == 0) _op(address(tracker), abi.encodeCall(tracker.createPlan, (YIELD_FEE, abi.encode(YieldFeeModule.Plan({rateBps: YIELD_DEFAULT_FEE_BPS})))));
    }

    /// @dev Registries, fee trackers and fee modules hold per-wallet or per-target state, so replacing one is a migration:
    ///      the replacement must import that state (see the README), and is set deliberately, not by re-running Deploy
    function _requireNotReplaced(address current, address next, string memory name) internal pure {
        require(current == address(0) || current == next, string.concat("Refusing to replace ", name, ": it holds wallet or target state; deploy a replacement that imports it and set it deliberately"));
    }

    function _registerAdapter(AdapterRegistry registry, address adapter) internal {
        if (!registry.isRegisteredAdapter(adapter)) _op(address(registry), abi.encodeCall(registry.registerAdapter, (adapter)));
    }

    function _grantEmergencyRole(address target) internal {
        if (target == address(0) || IAccessControl(target).hasRole(EMERGENCY_ROLE, KRISHAN711_ETH)) return;
        console2.log("-> Preparing EMERGENCY_ROLE grant for krishan711.eth on:", target);
        _op(target, abi.encodeCall(IAccessControl.grantRole, (EMERGENCY_ROLE, KRISHAN711_ETH)));
    }

    function _setTarget(AdapterRegistry registry, address target, address adapter) internal {
        if (registry.getTargetAdapter(target) != adapter) {
            _op(address(registry), abi.encodeCall(registry.setTargetAdapter, (target, adapter)));
        }
    }

    function scheduleAndExecuteBatch(AdminTimelock adminTimelock, address[] memory targets, uint256[] memory values, bytes[] memory datas, uint256 delay, bytes32 salt) internal {
        bytes32 operationId = adminTimelock.hashOperationBatch(targets, values, datas, bytes32(0), salt);
        console2.log("   Batch operation ID:", vm.toString(operationId));
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
