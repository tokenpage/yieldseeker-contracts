// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {IPriceFeed, YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {YieldSeekerFeeTracker as LegacyFeeTracker} from "../src/_old/FeeTracker.sol";
import {YieldSeekerAaveV3LendingAdapter as AaveV3LendingAdapter} from "../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../src/adapters/AaveV4LendingAdapter.sol";
import {YieldSeekerAerodromeCLPairSwapAdapter as AerodromeCLPairSwapAdapter} from "../src/adapters/AerodromeCLPairSwapAdapter.sol";
import {YieldSeekerAerodromeV2PairSwapAdapter as AerodromeV2PairSwapAdapter} from "../src/adapters/AerodromeV2PairSwapAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter as MorphoBlueLendingAdapter} from "../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerTransferAdapter as TransferAdapter} from "../src/adapters/TransferAdapter.sol";
import {YieldSeekerUniswapV3PairSwapAdapter as UniswapV3PairSwapAdapter} from "../src/adapters/UniswapV3PairSwapAdapter.sol";
import {AWKAdapterRegistry} from "../src/agentwalletkit/AWKAdapterRegistry.sol";
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
 * @title DeployV3Script
 * @notice Deploys the profile factory, V3 wallet, fee modules and borrow adapters, and schedules one timelock
 *         batch that configures them. The old factory, its wallets and FeeTracker are untouched; the vault profile
 *         reuses the existing vault adapter registry.
 * @dev Usage: SERVER_ADDRESS=... PLAN_MANAGER_ADDRESS=... EMERGENCY_ADMIN_ADDRESS=... forge script script/DeployV3.s.sol:DeployV3Script
 *             --rpc-url <RPC> --sender <timelock proposer> --account <keystore> --broadcast
 *      Reads ./deployments.json (existing stack) and writes ./deployments-v3.json.
 */
contract DeployV3Script is Script {
    using stdJson for string;

    uint256 constant SALT = 0x713;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant VAULT_PROFILE = keccak256("vault");
    bytes32 constant BORROW_PROFILE = keccak256("borrow");
    uint256 constant VAULT_MAX_FEE_BPS = 5000;
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
    address constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant AERODROME_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant AERODROME_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    struct Existing {
        address adminTimelock;
        address vaultAdapterRegistry;
        address feeTracker;
        address merklAdapter;
    }

    struct Deployments {
        address agentWalletFactory;
        address agentWalletImplementation;
        address borrowAdapterRegistry;
        address priceOracle;
        address vaultFeeModule;
        address borrowFeeModule;
        address borrowRewardSellPolicy;
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

    function run() public {
        address serverAddress = vm.envAddress("SERVER_ADDRESS");
        address planManagerAddress = vm.envAddress("PLAN_MANAGER_ADDRESS");
        address emergencyAdminAddress = vm.envAddress("EMERGENCY_ADMIN_ADDRESS");
        string memory existingJson = vm.readFile("./deployments.json");
        Existing memory existing = Existing({
            adminTimelock: existingJson.readAddress(".adminTimelock"),
            vaultAdapterRegistry: existingJson.readAddress(".adapterRegistry"),
            feeTracker: existingJson.readAddress(".feeTracker"),
            merklAdapter: existingJson.readAddress(".merklAdapter")
        });
        address feeCollector = LegacyFeeTracker(existing.feeTracker).feeCollector();
        uint256 vaultFeeBps = LegacyFeeTracker(existing.feeTracker).feeRateBps();
        console2.log("Timelock:", existing.adminTimelock);
        console2.log("Server:", serverAddress);
        console2.log("Plan manager:", planManagerAddress);
        console2.log("Fee collector:", feeCollector);
        console2.log("Vault fee (bps):", vaultFeeBps);

        vm.startBroadcast();
        Deployments memory d;
        d.agentWalletFactory = _deploy("AgentWalletFactory", abi.encodePacked(type(AgentWalletFactory).creationCode, abi.encode(existing.adminTimelock, serverAddress)));
        d.agentWalletImplementation = _deploy("AgentWalletV3", abi.encodePacked(type(AgentWallet).creationCode, abi.encode(d.agentWalletFactory)));
        d.borrowAdapterRegistry = _deploy("BorrowAdapterRegistry", abi.encodePacked(type(AdapterRegistry).creationCode, abi.encode(existing.adminTimelock, emergencyAdminAddress)));
        d.priceOracle = _deploy("PriceOracle", abi.encodePacked(type(PriceOracle).creationCode, abi.encode(existing.adminTimelock, emergencyAdminAddress, SEQUENCER_UPTIME_FEED)));
        d.vaultFeeModule = _deploy("VaultFeeTracker", abi.encodePacked(type(FeeTracker).creationCode, abi.encode(existing.adminTimelock, planManagerAddress, feeCollector, VAULT_MAX_FEE_BPS, vaultFeeBps)));
        d.borrowFeeModule = _deploy("BorrowFeeModule", abi.encodePacked(type(BorrowFeeModule).creationCode, abi.encode(existing.adminTimelock, planManagerAddress, feeCollector, BORROW_MAX_FEE_BPS, BORROW_DEFAULT_FEE_BPS)));
        d.borrowRewardSellPolicy = _deploy("BorrowRewardSellPolicy", abi.encodePacked(type(SwapSellPolicy).creationCode, abi.encode(existing.adminTimelock, emergencyAdminAddress, false)));
        d.walletLinkRegistry = _deploy("WalletLinkRegistry", type(WalletLinkRegistry).creationCode);
        d.aaveV3LendingAdapter = _deploy("AaveV3LendingAdapter", abi.encodePacked(type(AaveV3LendingAdapter).creationCode, abi.encode(d.priceOracle)));
        d.aaveV4LendingAdapter = _deploy("AaveV4LendingAdapter", abi.encodePacked(type(AaveV4LendingAdapter).creationCode, abi.encode(d.priceOracle)));
        d.morphoBlueLendingAdapter = _deploy("MorphoBlueLendingAdapter", abi.encodePacked(type(MorphoBlueLendingAdapter).creationCode, abi.encode(d.priceOracle)));
        d.uniswapV3PairSwapAdapter = _deploy("UniswapV3PairSwapAdapter", abi.encodePacked(type(UniswapV3PairSwapAdapter).creationCode, abi.encode(UNISWAP_V3_ROUTER, d.borrowRewardSellPolicy, d.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
        d.aerodromeV2PairSwapAdapter =
            _deploy("AerodromeV2PairSwapAdapter", abi.encodePacked(type(AerodromeV2PairSwapAdapter).creationCode, abi.encode(AERODROME_V2_ROUTER, AERODROME_V2_FACTORY, d.borrowRewardSellPolicy, d.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
        d.aerodromeClPairSwapAdapter =
            _deploy("AerodromeCLPairSwapAdapter", abi.encodePacked(type(AerodromeCLPairSwapAdapter).creationCode, abi.encode(AERODROME_CL_ROUTER, d.borrowRewardSellPolicy, d.priceOracle, PAIR_SWAP_MAX_SLIPPAGE_BPS)));
        d.transferAdapter = _deploy("TransferAdapter", abi.encodePacked(type(TransferAdapter).creationCode, abi.encode(d.walletLinkRegistry)));
        _writeDeployments(d);

        _buildConfiguration(existing, d);
        uint256[] memory values = new uint256[](_targets.length);
        AdminTimelock adminTimelock = AdminTimelock(payable(existing.adminTimelock));
        bytes32 salt = bytes32(uint256(3000));
        adminTimelock.scheduleBatch(_targets, values, _datas, bytes32(0), salt, adminTimelock.getMinDelay());
        console2.log("-> Scheduled", _targets.length, "operations; batch id:", vm.toString(adminTimelock.hashOperationBatch(_targets, values, _datas, bytes32(0), salt)));
        vm.stopBroadcast();
    }

    function _buildConfiguration(Existing memory existing, Deployments memory d) internal {
        AgentWalletFactory factory = AgentWalletFactory(d.agentWalletFactory);
        AdapterRegistry borrowRegistry = AdapterRegistry(d.borrowAdapterRegistry);
        AdapterRegistry vaultRegistry = AdapterRegistry(existing.vaultAdapterRegistry);
        PriceOracle oracle = PriceOracle(d.priceOracle);

        _op(d.agentWalletFactory, abi.encodeCall(factory.setAgentWalletImplementation, (AgentWallet(payable(d.agentWalletImplementation)))));
        _op(d.agentWalletFactory, abi.encodeCall(factory.setAdapterRegistry, (VAULT_PROFILE, vaultRegistry)));
        _op(d.agentWalletFactory, abi.encodeCall(factory.setFeeTracker, (VAULT_PROFILE, FeeTracker(d.vaultFeeModule))));
        _op(d.agentWalletFactory, abi.encodeCall(factory.setAdapterRegistry, (BORROW_PROFILE, borrowRegistry)));
        _op(d.agentWalletFactory, abi.encodeCall(factory.setFeeTracker, (BORROW_PROFILE, FeeTracker(d.borrowFeeModule))));

        _op(d.priceOracle, abi.encodeCall(oracle.setSource, (WETH, IPriceFeed(ETH_USD_FEED), 1 hours)));
        _op(d.priceOracle, abi.encodeCall(oracle.setSource, (CBBTC, IPriceFeed(CBBTC_USD_FEED), 1 hours)));
        _op(d.priceOracle, abi.encodeCall(oracle.setSource, (USDC, IPriceFeed(USDC_USD_FEED), 25 hours)));

        _registerMarket(borrowRegistry, d.aaveV3LendingAdapter, abi.encode(AAVE_V3_POOL, WETH, USDC, uint8(0)));
        _registerMarket(borrowRegistry, d.aaveV3LendingAdapter, abi.encode(AAVE_V3_POOL, CBBTC, USDC, uint8(0)));
        _registerMarket(borrowRegistry, d.morphoBlueLendingAdapter, abi.encode(MORPHO_BLUE, IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: WETH, oracle: MORPHO_WETH_USDC_ORACLE, irm: MORPHO_ADAPTIVE_IRM, lltv: 0.86e18})));
        _registerMarket(borrowRegistry, d.morphoBlueLendingAdapter, abi.encode(MORPHO_BLUE, IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: CBBTC, oracle: MORPHO_CBBTC_USDC_ORACLE, irm: MORPHO_ADAPTIVE_IRM, lltv: 0.86e18})));
        IAaveV4Oracle spokeOracle = IAaveV4Oracle(IAaveV4SpokeOracle(AAVE_V4_MAG7_SPOKE).ORACLE());
        uint256 reserveCount = IAaveV4SpokeOracle(AAVE_V4_MAG7_SPOKE).getReserveCount();
        for (uint256 reserveId = 0; reserveId < reserveCount; reserveId++) {
            if (reserveId == AAVE_V4_MAG7_USDC_RESERVE) continue;
            address collateral = IAaveV4Spoke(AAVE_V4_MAG7_SPOKE).getReserve(reserveId).underlying;
            if (collateral != WETH && collateral != CBBTC && collateral != USDC) {
                _op(d.priceOracle, abi.encodeCall(oracle.setSource, (collateral, IPriceFeed(spokeOracle.getReserveSource(reserveId)), 4 days)));
            }
            _registerMarket(borrowRegistry, d.aaveV4LendingAdapter, abi.encode(AAVE_V4_MAG7_SPOKE, reserveId, AAVE_V4_MAG7_USDC_RESERVE));
        }

        _registerTarget(borrowRegistry, d.uniswapV3PairSwapAdapter, UNISWAP_V3_ROUTER);
        _registerTarget(borrowRegistry, d.aerodromeV2PairSwapAdapter, AERODROME_V2_ROUTER);
        _registerTarget(borrowRegistry, d.aerodromeClPairSwapAdapter, AERODROME_CL_ROUTER);
        _registerTarget(borrowRegistry, existing.merklAdapter, MERKL_DISTRIBUTOR);
        _registerTarget(borrowRegistry, d.transferAdapter, d.walletLinkRegistry);
        _registerTarget(vaultRegistry, d.transferAdapter, d.walletLinkRegistry);
    }

    function _registerMarket(AdapterRegistry registry, address adapter, bytes memory market) internal {
        _registerTarget(registry, adapter, AWKLendingAdapter(adapter).marketTarget(market));
    }

    function _registerTarget(AdapterRegistry registry, address adapter, address target) internal {
        if (!registry.isRegisteredAdapter(adapter) && !_isQueuedRegistration(address(registry), adapter)) _op(address(registry), abi.encodeCall(registry.registerAdapter, (adapter)));
        _op(address(registry), abi.encodeCall(registry.setTargetAdapter, (target, adapter)));
    }

    function _isQueuedRegistration(address registry, address adapter) internal view returns (bool) {
        bytes memory data = abi.encodeWithSelector(AWKAdapterRegistry.registerAdapter.selector, adapter);
        for (uint256 i = 0; i < _targets.length; i++) {
            if (_targets[i] == registry && keccak256(_datas[i]) == keccak256(data)) return true;
        }
        return false;
    }

    function _op(address target, bytes memory data) internal {
        _targets.push(target);
        _datas.push(data);
    }

    function _deploy(string memory label, bytes memory initCode) internal returns (address deployed) {
        bytes32 salt = bytes32(SALT);
        address predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, keccak256(initCode))))));
        if (predicted.code.length == 0) {
            (bool success,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(success && predicted.code.length > 0, "CREATE2 deployment failed");
        }
        console2.log(string.concat("-> ", label, ":"), predicted);
        return predicted;
    }

    function _writeDeployments(Deployments memory d) internal {
        string memory json = "v3";
        vm.serializeAddress(json, "agentWalletFactory", d.agentWalletFactory);
        vm.serializeAddress(json, "agentWalletImplementation", d.agentWalletImplementation);
        vm.serializeAddress(json, "borrowAdapterRegistry", d.borrowAdapterRegistry);
        vm.serializeAddress(json, "priceOracle", d.priceOracle);
        vm.serializeAddress(json, "vaultFeeModule", d.vaultFeeModule);
        vm.serializeAddress(json, "borrowFeeModule", d.borrowFeeModule);
        vm.serializeAddress(json, "borrowRewardSellPolicy", d.borrowRewardSellPolicy);
        vm.serializeAddress(json, "walletLinkRegistry", d.walletLinkRegistry);
        vm.serializeAddress(json, "aaveV3LendingAdapter", d.aaveV3LendingAdapter);
        vm.serializeAddress(json, "aaveV4LendingAdapter", d.aaveV4LendingAdapter);
        vm.serializeAddress(json, "morphoBlueLendingAdapter", d.morphoBlueLendingAdapter);
        vm.serializeAddress(json, "uniswapV3PairSwapAdapter", d.uniswapV3PairSwapAdapter);
        vm.serializeAddress(json, "aerodromeV2PairSwapAdapter", d.aerodromeV2PairSwapAdapter);
        vm.serializeAddress(json, "aerodromeCLPairSwapAdapter", d.aerodromeClPairSwapAdapter);
        string memory finalJson = vm.serializeAddress(json, "transferAdapter", d.transferAdapter);
        vm.writeJson(finalJson, "./deployments-v3.json");
    }
}
