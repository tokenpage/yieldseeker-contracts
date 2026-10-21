// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {IPriceFeed, YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerAaveV3LendingAdapter as AaveV3LendingAdapter} from "../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../src/adapters/AaveV4LendingAdapter.sol";
import {YieldSeekerAerodromeCLPairSwapAdapter as AerodromeCLPairSwapAdapter} from "../src/adapters/AerodromeCLPairSwapAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2PairSwapAdapter as AerodromeV2PairSwapAdapter} from "../src/adapters/AerodromeV2PairSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {YieldSeekerMoonwellRewardAdapter as MoonwellRewardAdapter} from "../src/adapters/MoonwellRewardAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter as MorphoBlueLendingAdapter} from "../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerTransferAdapter as TransferAdapter} from "../src/adapters/TransferAdapter.sol";
import {YieldSeekerUniswapV3PairSwapAdapter as UniswapV3PairSwapAdapter} from "../src/adapters/UniswapV3PairSwapAdapter.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKWalletLinkRegistry as WalletLinkRegistry} from "../src/agentwalletkit/AWKWalletLinkRegistry.sol";
import {IAaveV4Spoke} from "../src/agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {AWKLendingAdapter} from "../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {IMorphoBlue} from "../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {YieldSeekerBorrowFeeModule as BorrowFeeModule} from "../src/fees/BorrowFeeModule.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

interface IAaveV4SpokeOracle {
    function ORACLE() external view returns (address);
    function getReserveCount() external view returns (uint256);
}

interface IAaveV4Oracle {
    function getReserveSource(uint256 reserveId) external view returns (address);
}

/**
 * @title DeployScript
 * @notice Deploys the YieldSeeker AgentWallet system with selective contract deployment.
 * @dev Usage: forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC> --broadcast
 */
contract DeployScript is Script {
    using stdJson for string;
    // Canonical ERC-4337 v0.6 EntryPoint
    address constant ENTRYPOINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    // Deployment Salt for deterministic addresses
    uint256 constant SALT = 0x712;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Testing Mode: Set to true to deploy with 0-delay adminTimelock for faster testing
    // Set to false for production (uses 4-day delay)
    bool constant TESTING_MODE = false;

    bytes32 constant VAULT_PROFILE = keccak256("vault");
    bytes32 constant BORROW_PROFILE = keccak256("borrow");
    uint256 constant VAULT_MAX_FEE_BPS = 5000;
    uint256 constant VAULT_DEFAULT_FEE_BPS = 1000;
    uint256 constant BORROW_MAX_FEE_BPS = 200;
    uint256 constant BORROW_DEFAULT_FEE_BPS = 50;
    uint256 constant PAIR_SWAP_MAX_SLIPPAGE_BPS = 100;

    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant CBBTC_USD_FEED = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant AAVE_V4_MAG7_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
    uint256 constant AAVE_V4_MAG7_USDC_RESERVE = 7;
    address constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant MORPHO_ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address constant MORPHO_WETH_USDC_ORACLE = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant MORPHO_CBBTC_USDC_ORACLE = 0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    // State tracking
    struct Deployments {
        address adminTimelock;
        address agentWalletFactory;
        address adapterRegistry;
        address agentWalletImplementation;
        address agentWalletV1Implementation;
        address agentWalletV2Implementation;
        address agentWalletV2Factory;
        address agentWalletV2FeeTracker;
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
        address moonwellRewardAdapter;
        address borrowAdapterRegistry;
        address borrowFeeModule;
        address borrowSwapSellPolicy;
        address priceOracle;
        address walletLinkRegistry;
        address aaveV3LendingAdapter;
        address aaveV4LendingAdapter;
        address morphoBlueLendingAdapter;
        address uniswapV3PairSwapAdapter;
        address aerodromeV2PairSwapAdapter;
        address aerodromeClPairSwapAdapter;
        address transferAdapter;
    }

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

    function deployCreate2(bytes memory initCode) internal returns (address deployed) {
        bytes32 salt = bytes32(SALT);
        require(CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer has no code");
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode))))));
        (bool success, bytes memory returnData) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(success, "CREATE2 deployment failed");
        require(returnData.length == 20, "CREATE2 deployer returned invalid address");
        assembly ("memory-safe") {
            deployed := shr(96, mload(add(returnData, 32)))
        }
        require(deployed == predicted, "CREATE2 address mismatch");
        require(deployed.code.length > 0, "CREATE2 deployment produced no code");
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

    function getWellToken(uint256 chainId) internal pure returns (address) {
        if (chainId == 8453) {
            return 0xA88594D404727625A9437C3f886C7643872296AE;
        }
        revert(string.concat("Unsupported chain id for WELL token: ", vm.toString(chainId)));
    }

    function run() public {
        address serverAddress = vm.envAddress("SERVER_ADDRESS");
        address planManagerAddress = vm.envAddress("PLAN_MANAGER_ADDRESS");
        address feeCollectorAddress = vm.envAddress("FEE_COLLECTOR_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address configuredMultisigAdminAddress = vm.envAddress("MULTISIG_ADMIN_ADDRESS");
        address multisigAdminAddress = TESTING_MODE ? deployerAddress : configuredMultisigAdminAddress;
        address timelockProposerAddress = deployerAddress;
        address timelockExecutorAddress = TESTING_MODE ? deployerAddress : multisigAdminAddress;
        address timelockAdminAddress = TESTING_MODE ? deployerAddress : multisigAdminAddress;
        address emergencyAdminAddress = deployerAddress;
        uint256 adminTimelockDelay = TESTING_MODE ? 0 : 4 days;
        address uniswapV3Router = getUniswapV3Router(block.chainid);
        address aerodromeV2Router = getAerodromeV2Router(block.chainid);
        address aerodromeV2Factory = getAerodromeV2Factory(block.chainid);
        address aerodromeClRouter = getAerodromeClRouter(block.chainid);

        console2.log("=================================================");
        console2.log("YIELDSEEKER DEPLOYMENT SCRIPT");
        console2.log("=================================================");
        console2.log("Deployer:", deployerAddress);
        console2.log("Multisig Admin:", multisigAdminAddress);
        console2.log("Server:", serverAddress);
        console2.log("Plan Manager:", planManagerAddress);
        console2.log("Fee Collector:", feeCollectorAddress);
        console2.log("Timelock Proposer:", timelockProposerAddress);
        console2.log("Timelock Executor:", timelockExecutorAddress);
        console2.log("Timelock Admin:", timelockAdminAddress);
        console2.log("Emergency Admin:", emergencyAdminAddress);
        console2.log("Timelock Delay:", adminTimelockDelay);
        console2.log("Testing Mode:", TESTING_MODE);
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
                agentWalletV1Implementation: safeReadAddress(deployJson, ".agentWalletV1Implementation"),
                agentWalletV2Implementation: safeReadAddress(deployJson, ".agentWalletV2Implementation"),
                agentWalletV2Factory: safeReadAddress(deployJson, ".agentWalletV2Factory"),
                agentWalletV2FeeTracker: safeReadAddress(deployJson, ".agentWalletV2FeeTracker"),
                feeTracker: safeReadAddress(deployJson, ".feeTracker"),
                erc4626Adapter: safeReadAddress(deployJson, ".erc4626Adapter"),
                merklAdapter: safeReadAddress(deployJson, ".merklAdapter"),
                swapSellPolicy: safeReadAddress(deployJson, ".swapSellPolicy"),
                uniswapV3SwapAdapter: safeReadAddress(deployJson, ".uniswapV3SwapAdapter"),
                aerodromeV2SwapAdapter: safeReadAddress(deployJson, ".aerodromeV2SwapAdapter"),
                aerodromeClSwapAdapter: safeReadAddress(deployJson, ".aerodromeCLSwapAdapter"),
                aaveV3Adapter: safeReadAddress(deployJson, ".aaveV3Adapter"),
                compoundV3Adapter: safeReadAddress(deployJson, ".compoundV3Adapter"),
                compoundV2Adapter: safeReadAddress(deployJson, ".compoundV2Adapter"),
                moonwellRewardAdapter: safeReadAddress(deployJson, ".moonwellRewardAdapter"),
                borrowAdapterRegistry: safeReadAddress(deployJson, ".borrowAdapterRegistry"),
                borrowFeeModule: safeReadAddress(deployJson, ".borrowFeeModule"),
                borrowSwapSellPolicy: safeReadAddress(deployJson, ".borrowSwapSellPolicy"),
                priceOracle: safeReadAddress(deployJson, ".priceOracle"),
                walletLinkRegistry: safeReadAddress(deployJson, ".walletLinkRegistry"),
                aaveV3LendingAdapter: safeReadAddress(deployJson, ".aaveV3LendingAdapter"),
                aaveV4LendingAdapter: safeReadAddress(deployJson, ".aaveV4LendingAdapter"),
                morphoBlueLendingAdapter: safeReadAddress(deployJson, ".morphoBlueLendingAdapter"),
                uniswapV3PairSwapAdapter: safeReadAddress(deployJson, ".uniswapV3PairSwapAdapter"),
                aerodromeV2PairSwapAdapter: safeReadAddress(deployJson, ".aerodromeV2PairSwapAdapter"),
                aerodromeClPairSwapAdapter: safeReadAddress(deployJson, ".aerodromeCLPairSwapAdapter"),
                transferAdapter: safeReadAddress(deployJson, ".transferAdapter")
            });
        }

        vm.startBroadcast(deployerPrivateKey);

        // Deploy or reuse AdminTimelock
        if (deployments.adminTimelock == address(0)) {
            address[] memory proposers = new address[](1);
            proposers[0] = timelockProposerAddress;
            address[] memory executors = new address[](1);
            executors[0] = timelockExecutorAddress;
            deployments.adminTimelock = deployCreate2(abi.encodePacked(type(AdminTimelock).creationCode, abi.encode(adminTimelockDelay, proposers, executors, timelockAdminAddress)));
            console2.log("-> AdminTimelock deployed at:", deployments.adminTimelock);
            console2.log("   delay (seconds):", adminTimelockDelay);
        } else {
            console2.log("-> Using existing adminTimelock:", deployments.adminTimelock);
        }

        // Deploy or reuse AgentWalletFactory
        if (deployments.agentWalletFactory == address(0)) {
            deployments.agentWalletFactory = deployCreate2(abi.encodePacked(type(AgentWalletFactory).creationCode, abi.encode(deployments.adminTimelock, serverAddress)));
            console2.log("-> AgentWalletFactory deployed at:", deployments.agentWalletFactory);
            console2.log("   AGENT_OPERATOR_ROLE granted to:", serverAddress);
        } else {
            console2.log("-> Using existing agentWalletFactory:", deployments.agentWalletFactory);
        }

        // Deploy or reuse AgentWallet V3 implementation
        if (deployments.agentWalletImplementation == address(0)) {
            deployments.agentWalletImplementation = deployCreate2(abi.encodePacked(type(AgentWallet).creationCode, abi.encode(deployments.agentWalletFactory)));
            console2.log("-> AgentWallet Implementation deployed at:", deployments.agentWalletImplementation);
        } else {
            console2.log("-> Using existing agentWalletImplementation:", deployments.agentWalletImplementation);
        }

        // Deploy or reuse AdapterRegistry
        if (deployments.adapterRegistry == address(0)) {
            deployments.adapterRegistry = deployCreate2(abi.encodePacked(type(AdapterRegistry).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress)));
            console2.log("-> AdapterRegistry deployed at:", deployments.adapterRegistry);
        } else {
            console2.log("-> Using existing adapterRegistry:", deployments.adapterRegistry);
        }

        // Deploy or reuse FeeTracker
        if (deployments.feeTracker == address(0)) {
            deployments.feeTracker = deployCreate2(abi.encodePacked(type(FeeTracker).creationCode, abi.encode(deployments.adminTimelock, planManagerAddress, feeCollectorAddress, VAULT_MAX_FEE_BPS, VAULT_DEFAULT_FEE_BPS)));
            console2.log("-> FeeTracker deployed at:", deployments.feeTracker);
        } else {
            console2.log("-> Using existing feeTracker:", deployments.feeTracker);
        }

        // Deploy or reuse ERC4626 Adapter
        if (deployments.erc4626Adapter == address(0)) {
            deployments.erc4626Adapter = deployCreate2(abi.encodePacked(type(ERC4626Adapter).creationCode));
            console2.log("-> ERC4626Adapter deployed at:", deployments.erc4626Adapter);
        } else {
            console2.log("-> Using existing erc4626Adapter:", deployments.erc4626Adapter);
        }

        // Deploy or reuse Merkl Adapter
        if (deployments.merklAdapter == address(0)) {
            deployments.merklAdapter = deployCreate2(abi.encodePacked(type(MerklAdapter).creationCode));
            console2.log("-> MerklAdapter deployed at:", deployments.merklAdapter);
        } else {
            console2.log("-> Using existing merklAdapter:", deployments.merklAdapter);
        }

        if (deployments.swapSellPolicy == address(0)) {
            deployments.swapSellPolicy = deployCreate2(abi.encodePacked(type(SwapSellPolicy).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress, false)));
            console2.log("-> SwapSellPolicy deployed at:", deployments.swapSellPolicy);
        } else {
            console2.log("-> Using existing swapSellPolicy:", deployments.swapSellPolicy);
        }

        if (deployments.uniswapV3SwapAdapter == address(0)) {
            deployments.uniswapV3SwapAdapter = deployCreate2(abi.encodePacked(type(UniswapV3SwapAdapter).creationCode, abi.encode(uniswapV3Router, deployments.swapSellPolicy)));
            console2.log("-> UniswapV3SwapAdapter deployed at:", deployments.uniswapV3SwapAdapter);
        } else {
            console2.log("-> Using existing uniswapV3SwapAdapter:", deployments.uniswapV3SwapAdapter);
        }

        if (deployments.aerodromeV2SwapAdapter == address(0)) {
            deployments.aerodromeV2SwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeV2SwapAdapter).creationCode, abi.encode(aerodromeV2Router, aerodromeV2Factory, deployments.swapSellPolicy)));
            console2.log("-> AerodromeV2SwapAdapter deployed at:", deployments.aerodromeV2SwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeV2SwapAdapter:", deployments.aerodromeV2SwapAdapter);
        }

        if (deployments.aerodromeClSwapAdapter == address(0)) {
            deployments.aerodromeClSwapAdapter = deployCreate2(abi.encodePacked(type(AerodromeCLSwapAdapter).creationCode, abi.encode(aerodromeClRouter, deployments.swapSellPolicy)));
            console2.log("-> AerodromeCLSwapAdapter deployed at:", deployments.aerodromeClSwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCLSwapAdapter:", deployments.aerodromeClSwapAdapter);
        }

        // Deploy or reuse Aave V3 Adapter
        if (deployments.aaveV3Adapter == address(0)) {
            deployments.aaveV3Adapter = deployCreate2(abi.encodePacked(type(AaveV3Adapter).creationCode));
            console2.log("-> AaveV3Adapter deployed at:", deployments.aaveV3Adapter);
        } else {
            console2.log("-> Using existing aaveV3Adapter:", deployments.aaveV3Adapter);
        }

        // Deploy or reuse Compound V3 Adapter
        if (deployments.compoundV3Adapter == address(0)) {
            deployments.compoundV3Adapter = deployCreate2(abi.encodePacked(type(CompoundV3Adapter).creationCode));
            console2.log("-> CompoundV3Adapter deployed at:", deployments.compoundV3Adapter);
        } else {
            console2.log("-> Using existing compoundV3Adapter:", deployments.compoundV3Adapter);
        }

        // Deploy or reuse Compound V2 Adapter (for Moonwell and other Compound V2 forks)
        if (deployments.compoundV2Adapter == address(0)) {
            deployments.compoundV2Adapter = deployCreate2(abi.encodePacked(type(CompoundV2Adapter).creationCode));
            console2.log("-> CompoundV2Adapter deployed at:", deployments.compoundV2Adapter);
        } else {
            console2.log("-> Using existing compoundV2Adapter:", deployments.compoundV2Adapter);
        }

        // Deploy or reuse Moonwell Reward Adapter
        if (deployments.moonwellRewardAdapter == address(0)) {
            deployments.moonwellRewardAdapter = deployCreate2(abi.encodePacked(type(MoonwellRewardAdapter).creationCode, abi.encode(getWellToken(block.chainid))));
            console2.log("-> MoonwellRewardAdapter deployed at:", deployments.moonwellRewardAdapter);
        } else {
            console2.log("-> Using existing moonwellRewardAdapter:", deployments.moonwellRewardAdapter);
        }

        if (deployments.borrowAdapterRegistry == address(0)) {
            deployments.borrowAdapterRegistry = deployCreate2(abi.encodePacked(type(AdapterRegistry).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress)));
            console2.log("-> Borrow AdapterRegistry deployed at:", deployments.borrowAdapterRegistry);
        } else {
            console2.log("-> Using existing borrowAdapterRegistry:", deployments.borrowAdapterRegistry);
        }

        if (deployments.borrowFeeModule == address(0)) {
            deployments.borrowFeeModule = deployCreate2(abi.encodePacked(type(BorrowFeeModule).creationCode, abi.encode(deployments.adminTimelock, planManagerAddress, feeCollectorAddress, BORROW_MAX_FEE_BPS, BORROW_DEFAULT_FEE_BPS)));
            console2.log("-> BorrowFeeModule deployed at:", deployments.borrowFeeModule);
        } else {
            console2.log("-> Using existing borrowFeeModule:", deployments.borrowFeeModule);
        }

        if (deployments.borrowSwapSellPolicy == address(0)) {
            deployments.borrowSwapSellPolicy = deployCreate2(abi.encodePacked(type(SwapSellPolicy).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress, false)));
            console2.log("-> Borrow SwapSellPolicy deployed at:", deployments.borrowSwapSellPolicy);
        } else {
            console2.log("-> Using existing borrowSwapSellPolicy:", deployments.borrowSwapSellPolicy);
        }

        if (deployments.priceOracle == address(0)) {
            deployments.priceOracle = deployCreate2(abi.encodePacked(type(PriceOracle).creationCode, abi.encode(deployments.adminTimelock, emergencyAdminAddress, SEQUENCER_UPTIME_FEED)));
            console2.log("-> PriceOracle deployed at:", deployments.priceOracle);
        } else {
            console2.log("-> Using existing priceOracle:", deployments.priceOracle);
        }

        if (deployments.walletLinkRegistry == address(0)) {
            deployments.walletLinkRegistry = deployCreate2(type(WalletLinkRegistry).creationCode);
            console2.log("-> WalletLinkRegistry deployed at:", deployments.walletLinkRegistry);
        } else {
            console2.log("-> Using existing walletLinkRegistry:", deployments.walletLinkRegistry);
        }

        if (deployments.aaveV3LendingAdapter == address(0)) {
            deployments.aaveV3LendingAdapter = deployCreate2(abi.encodePacked(type(AaveV3LendingAdapter).creationCode, abi.encode(deployments.priceOracle)));
            console2.log("-> AaveV3LendingAdapter deployed at:", deployments.aaveV3LendingAdapter);
        } else {
            console2.log("-> Using existing aaveV3LendingAdapter:", deployments.aaveV3LendingAdapter);
        }

        if (deployments.aaveV4LendingAdapter == address(0)) {
            deployments.aaveV4LendingAdapter = deployCreate2(abi.encodePacked(type(AaveV4LendingAdapter).creationCode, abi.encode(deployments.priceOracle)));
            console2.log("-> AaveV4LendingAdapter deployed at:", deployments.aaveV4LendingAdapter);
        } else {
            console2.log("-> Using existing aaveV4LendingAdapter:", deployments.aaveV4LendingAdapter);
        }

        if (deployments.morphoBlueLendingAdapter == address(0)) {
            deployments.morphoBlueLendingAdapter = deployCreate2(abi.encodePacked(type(MorphoBlueLendingAdapter).creationCode, abi.encode(deployments.priceOracle)));
            console2.log("-> MorphoBlueLendingAdapter deployed at:", deployments.morphoBlueLendingAdapter);
        } else {
            console2.log("-> Using existing morphoBlueLendingAdapter:", deployments.morphoBlueLendingAdapter);
        }

        if (deployments.uniswapV3PairSwapAdapter == address(0)) {
            deployments.uniswapV3PairSwapAdapter =
                deployCreate2(abi.encodePacked(type(UniswapV3PairSwapAdapter).creationCode, abi.encode(uniswapV3Router, deployments.borrowSwapSellPolicy, deployments.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
            console2.log("-> UniswapV3PairSwapAdapter deployed at:", deployments.uniswapV3PairSwapAdapter);
        } else {
            console2.log("-> Using existing uniswapV3PairSwapAdapter:", deployments.uniswapV3PairSwapAdapter);
        }

        if (deployments.aerodromeV2PairSwapAdapter == address(0)) {
            deployments.aerodromeV2PairSwapAdapter =
                deployCreate2(abi.encodePacked(type(AerodromeV2PairSwapAdapter).creationCode, abi.encode(aerodromeV2Router, aerodromeV2Factory, deployments.borrowSwapSellPolicy, deployments.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
            console2.log("-> AerodromeV2PairSwapAdapter deployed at:", deployments.aerodromeV2PairSwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeV2PairSwapAdapter:", deployments.aerodromeV2PairSwapAdapter);
        }

        if (deployments.aerodromeClPairSwapAdapter == address(0)) {
            deployments.aerodromeClPairSwapAdapter =
                deployCreate2(abi.encodePacked(type(AerodromeCLPairSwapAdapter).creationCode, abi.encode(aerodromeClRouter, deployments.borrowSwapSellPolicy, deployments.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
            console2.log("-> AerodromeCLPairSwapAdapter deployed at:", deployments.aerodromeClPairSwapAdapter);
        } else {
            console2.log("-> Using existing aerodromeCLPairSwapAdapter:", deployments.aerodromeClPairSwapAdapter);
        }

        if (deployments.transferAdapter == address(0)) {
            deployments.transferAdapter = deployCreate2(abi.encodePacked(type(TransferAdapter).creationCode, abi.encode(deployments.walletLinkRegistry)));
            console2.log("-> TransferAdapter deployed at:", deployments.transferAdapter);
        } else {
            console2.log("-> Using existing transferAdapter:", deployments.transferAdapter);
        }

        // Export deployments to JSON
        string memory json = "json";
        vm.serializeAddress(json, "adminTimelock", deployments.adminTimelock);
        vm.serializeAddress(json, "agentWalletFactory", deployments.agentWalletFactory);
        vm.serializeAddress(json, "adapterRegistry", deployments.adapterRegistry);
        vm.serializeAddress(json, "agentWalletImplementation", deployments.agentWalletImplementation);
        vm.serializeAddress(json, "agentWalletV1Implementation", deployments.agentWalletV1Implementation);
        vm.serializeAddress(json, "agentWalletV2Implementation", deployments.agentWalletV2Implementation);
        vm.serializeAddress(json, "agentWalletV2Factory", deployments.agentWalletV2Factory);
        vm.serializeAddress(json, "agentWalletV2FeeTracker", deployments.agentWalletV2FeeTracker);
        vm.serializeAddress(json, "feeTracker", deployments.feeTracker);
        vm.serializeAddress(json, "erc4626Adapter", deployments.erc4626Adapter);
        vm.serializeAddress(json, "merklAdapter", deployments.merklAdapter);
        vm.serializeAddress(json, "swapSellPolicy", deployments.swapSellPolicy);
        vm.serializeAddress(json, "uniswapV3SwapAdapter", deployments.uniswapV3SwapAdapter);
        vm.serializeAddress(json, "aerodromeV2SwapAdapter", deployments.aerodromeV2SwapAdapter);
        vm.serializeAddress(json, "aerodromeCLSwapAdapter", deployments.aerodromeClSwapAdapter);
        vm.serializeAddress(json, "aaveV3Adapter", deployments.aaveV3Adapter);
        vm.serializeAddress(json, "compoundV3Adapter", deployments.compoundV3Adapter);
        vm.serializeAddress(json, "compoundV2Adapter", deployments.compoundV2Adapter);
        vm.serializeAddress(json, "moonwellRewardAdapter", deployments.moonwellRewardAdapter);
        vm.serializeAddress(json, "borrowAdapterRegistry", deployments.borrowAdapterRegistry);
        vm.serializeAddress(json, "borrowFeeModule", deployments.borrowFeeModule);
        vm.serializeAddress(json, "borrowSwapSellPolicy", deployments.borrowSwapSellPolicy);
        vm.serializeAddress(json, "priceOracle", deployments.priceOracle);
        vm.serializeAddress(json, "walletLinkRegistry", deployments.walletLinkRegistry);
        vm.serializeAddress(json, "aaveV3LendingAdapter", deployments.aaveV3LendingAdapter);
        vm.serializeAddress(json, "aaveV4LendingAdapter", deployments.aaveV4LendingAdapter);
        vm.serializeAddress(json, "morphoBlueLendingAdapter", deployments.morphoBlueLendingAdapter);
        vm.serializeAddress(json, "uniswapV3PairSwapAdapter", deployments.uniswapV3PairSwapAdapter);
        vm.serializeAddress(json, "aerodromeV2PairSwapAdapter", deployments.aerodromeV2PairSwapAdapter);
        vm.serializeAddress(json, "aerodromeCLPairSwapAdapter", deployments.aerodromeClPairSwapAdapter);
        string memory finalJson = vm.serializeAddress(json, "transferAdapter", deployments.transferAdapter);
        vm.writeJson(finalJson, "./deployments.json");
        console2.log("-> Deployments saved to ./deployments.json");

        // Post-deployment configuration
        console2.log("");
        console2.log("=================================================");
        console2.log("POST-DEPLOYMENT CONFIGURATION");
        console2.log("=================================================");
        AdapterRegistry adapterRegistry = AdapterRegistry(deployments.adapterRegistry);
        AdapterRegistry borrowAdapterRegistry = AdapterRegistry(deployments.borrowAdapterRegistry);
        AgentWalletFactory agentWalletFactory = AgentWalletFactory(deployments.agentWalletFactory);
        PriceOracle priceOracle = PriceOracle(deployments.priceOracle);
        AdminTimelock adminTimelock = AdminTimelock(payable(deployments.adminTimelock));
        uint256 timelockDelay = adminTimelock.getMinDelay();

        // 1. Configure Factory
        console2.log("-> Preparing agentWalletFactory configuration...");
        if (address(agentWalletFactory.agentWalletImplementation()) != deployments.agentWalletImplementation) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAgentWalletImplementation, (AgentWallet(payable(deployments.agentWalletImplementation)))));
        }
        if (agentWalletFactory.profileAdapterRegistry(VAULT_PROFILE) != adapterRegistry) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAdapterRegistry, (VAULT_PROFILE, adapterRegistry)));
        }
        if (address(agentWalletFactory.profileFeeTracker(VAULT_PROFILE)) != deployments.feeTracker) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setFeeTracker, (VAULT_PROFILE, FeeTracker(deployments.feeTracker))));
        }
        if (agentWalletFactory.profileAdapterRegistry(BORROW_PROFILE) != borrowAdapterRegistry) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setAdapterRegistry, (BORROW_PROFILE, borrowAdapterRegistry)));
        }
        if (address(agentWalletFactory.profileFeeTracker(BORROW_PROFILE)) != deployments.borrowFeeModule) {
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.setFeeTracker, (BORROW_PROFILE, FeeTracker(deployments.borrowFeeModule))));
        }
        // 2. Register Adapters
        console2.log("-> Preparing adapter registration...");
        _registerAdapter(adapterRegistry, deployments.erc4626Adapter);
        _registerAdapter(adapterRegistry, deployments.merklAdapter);
        _registerAdapter(adapterRegistry, deployments.uniswapV3SwapAdapter);
        _registerAdapter(adapterRegistry, deployments.aerodromeV2SwapAdapter);
        _registerAdapter(adapterRegistry, deployments.aerodromeClSwapAdapter);
        _registerAdapter(adapterRegistry, deployments.aaveV3Adapter);
        _registerAdapter(adapterRegistry, deployments.compoundV3Adapter);
        _registerAdapter(adapterRegistry, deployments.compoundV2Adapter);
        _registerAdapter(adapterRegistry, deployments.moonwellRewardAdapter);
        _registerAdapter(adapterRegistry, deployments.transferAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aaveV3LendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aaveV4LendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.morphoBlueLendingAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.uniswapV3PairSwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeV2PairSwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.aerodromeClPairSwapAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.merklAdapter);
        _registerAdapter(borrowAdapterRegistry, deployments.transferAdapter);
        // 3. Set Borrow Targets and Price Sources
        console2.log("-> Preparing borrow targets and price sources...");
        _setTarget(adapterRegistry, deployments.walletLinkRegistry, deployments.transferAdapter);
        _setTarget(borrowAdapterRegistry, deployments.walletLinkRegistry, deployments.transferAdapter);
        _setTarget(borrowAdapterRegistry, uniswapV3Router, deployments.uniswapV3PairSwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeV2Router, deployments.aerodromeV2PairSwapAdapter);
        _setTarget(borrowAdapterRegistry, aerodromeClRouter, deployments.aerodromeClPairSwapAdapter);
        _setTarget(borrowAdapterRegistry, MERKL_DISTRIBUTOR, deployments.merklAdapter);
        _setMarket(borrowAdapterRegistry, deployments.aaveV3LendingAdapter, abi.encode(AAVE_V3_POOL, WETH, USDC, uint8(0)));
        _setMarket(borrowAdapterRegistry, deployments.aaveV3LendingAdapter, abi.encode(AAVE_V3_POOL, CBBTC, USDC, uint8(0)));
        _setMarket(
            borrowAdapterRegistry, deployments.morphoBlueLendingAdapter, abi.encode(MORPHO_BLUE, IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: WETH, oracle: MORPHO_WETH_USDC_ORACLE, irm: MORPHO_ADAPTIVE_IRM, lltv: 0.86e18}))
        );
        _setMarket(
            borrowAdapterRegistry, deployments.morphoBlueLendingAdapter, abi.encode(MORPHO_BLUE, IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: CBBTC, oracle: MORPHO_CBBTC_USDC_ORACLE, irm: MORPHO_ADAPTIVE_IRM, lltv: 0.86e18}))
        );
        _setPriceSource(priceOracle, WETH, ETH_USD_FEED, 1 hours);
        _setPriceSource(priceOracle, CBBTC, CBBTC_USD_FEED, 1 hours);
        _setPriceSource(priceOracle, USDC, USDC_USD_FEED, 25 hours);
        IAaveV4Oracle aaveV4Oracle = IAaveV4Oracle(IAaveV4SpokeOracle(AAVE_V4_MAG7_SPOKE).ORACLE());
        uint256 aaveV4ReserveCount = IAaveV4SpokeOracle(AAVE_V4_MAG7_SPOKE).getReserveCount();
        for (uint256 reserveId = 0; reserveId < aaveV4ReserveCount; reserveId++) {
            if (reserveId == AAVE_V4_MAG7_USDC_RESERVE) continue;
            address collateral = IAaveV4Spoke(AAVE_V4_MAG7_SPOKE).getReserve(reserveId).underlying;
            if (collateral != WETH && collateral != CBBTC && collateral != USDC) {
                _setPriceSource(priceOracle, collateral, aaveV4Oracle.getReserveSource(reserveId), 4 days);
            }
            _setMarket(borrowAdapterRegistry, deployments.aaveV4LendingAdapter, abi.encode(AAVE_V4_MAG7_SPOKE, reserveId, AAVE_V4_MAG7_USDC_RESERVE));
        }
        // 4. Set Agent Operator
        if (!agentWalletFactory.hasRole(agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)) {
            console2.log("-> Preparing AGENT_OPERATOR_ROLE grant for server:", serverAddress);
            _op(deployments.agentWalletFactory, abi.encodeCall(agentWalletFactory.grantRole, (agentWalletFactory.AGENT_OPERATOR_ROLE(), serverAddress)));
        } else {
            console2.log("-> Server already has AGENT_OPERATOR_ROLE");
        }
        // Execute batch if there are operations
        if (_targets.length > 0) {
            console2.log("-> Executing", _targets.length, "operations in batch...");
            scheduleAndExecuteBatch(adminTimelock, _targets, new uint256[](_targets.length), _datas, timelockDelay, bytes32(uint256(1000)));
            console2.log("-> Configuration complete!");
        } else {
            console2.log("-> No configuration needed, all settings are up to date!");
        }
        console2.log("=================================================");
        console2.log("You will need to register any specific vaults manually");
        console2.log("=================================================");
        vm.stopBroadcast();
    }

    function _op(address target, bytes memory data) internal {
        _targets.push(target);
        _datas.push(data);
    }

    function _registerAdapter(AdapterRegistry registry, address adapter) internal {
        if (!registry.isRegisteredAdapter(adapter)) _op(address(registry), abi.encodeCall(registry.registerAdapter, (adapter)));
    }

    function _setTarget(AdapterRegistry registry, address target, address adapter) internal {
        if (registry.getTargetAdapter(target) != adapter) _op(address(registry), abi.encodeCall(registry.setTargetAdapter, (target, adapter)));
    }

    function _setMarket(AdapterRegistry registry, address adapter, bytes memory market) internal {
        _setTarget(registry, AWKLendingAdapter(adapter).marketTarget(market), adapter);
    }

    function _setPriceSource(PriceOracle oracle, address asset, address feed, uint32 maxStaleness) internal {
        (IPriceFeed currentFeed, uint32 currentMaxStaleness) = oracle.sources(asset);
        if (address(currentFeed) != feed || currentMaxStaleness != maxStaleness) _op(address(oracle), abi.encodeCall(oracle.setSource, (asset, IPriceFeed(feed), maxStaleness)));
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
