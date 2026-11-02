pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {YieldSeekerWalletLinkRegistry as WalletLinkRegistry} from "../../src/WalletLinkRegistry.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerAaveV3LendingAdapter as AaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../../src/adapters/AaveV4LendingAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerAgentTransferAdapter as AgentTransferAdapter} from "../../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../../src/adapters/MerklAdapter.sol";
import {YieldSeekerMoonwellRewardAdapter as MoonwellRewardAdapter} from "../../src/adapters/MoonwellRewardAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter as MorphoBlueLendingAdapter} from "../../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterExecutionFailed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {IMorphoBlue} from "../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {YieldSeekerBorrowSwapPolicy} from "../../src/swaps/BorrowSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy} from "../../src/swaps/VaultSwapPolicy.sol";
import {MockAToken, MockAaveV3Pool} from "../mocks/MockAaveV3.sol";
import {MockCToken} from "../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../mocks/MockCompoundV3.sol";
import {MockERC20, MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockFeePriceFeed} from "../mocks/MockFeePriceFeed.sol";
import {MockAerodromeCLRouter, MockAerodromeV2Router, MockMerklDistributor, MockMoonwellComptroller, MockUniswapV3Router} from "../mocks/MockIntegrationMocks.sol";
import {MockAaveV3AddressesProvider, MockAaveV3Oracle, MockAaveV4Oracle, MockLendingAaveV3Pool, MockLendingAaveV4Spoke, MockLendingMorpho, MockMorphoOracle} from "../mocks/MockLendingMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

interface IMintableToken {
    function mint(address recipient, uint256 amount) external;
}

abstract contract IntegrationBase is Test {
    bytes32 public constant VAULT_AGENT_PROFILE = keccak256("vault");
    bytes32 public constant BORROW_AGENT_PROFILE = keccak256("borrow");
    uint256 public constant YIELD_FEE_BPS = 1000;
    uint256 public constant BORROW_FEE_BPS = 50;
    uint256 public constant BORROW_SWAP_MAX_SLIPPAGE_BPS = 100;

    address public admin;
    address public owner;
    address public operator;
    address public feeCollector;

    AgentWalletFactory public factory;
    AgentWallet public walletImplementation;
    FeeTracker public vaultFeeTracker;
    FeeTracker public borrowFeeTracker;
    YieldSeekerYieldFeeModule public vaultYieldFeeModule;
    YieldSeekerYieldFeeModule public borrowYieldFeeModule;
    YieldSeekerBorrowFeeModule public borrowFeeModule;
    AdapterRegistry public vaultRegistry;
    AdapterRegistry public borrowRegistry;
    SwapSellPolicy public swapSellPolicy;
    YieldSeekerVaultSwapPolicy public vaultSwapPolicy;
    YieldSeekerBorrowSwapPolicy public borrowSwapPolicy;
    YieldSeekerPriceOracle public priceOracle;

    ERC4626Adapter public erc4626Adapter;
    AaveV3Adapter public aaveV3Adapter;
    CompoundV3Adapter public compoundV3Adapter;
    CompoundV2Adapter public compoundV2Adapter;
    MoonwellRewardAdapter public moonwellRewardAdapter;
    MerklAdapter public merklAdapter;
    UniswapV3SwapAdapter public uniswapV3SwapAdapter;
    AerodromeV2SwapAdapter public aerodromeV2SwapAdapter;
    AerodromeCLSwapAdapter public aerodromeCLSwapAdapter;
    AgentTransferAdapter public agentTransferAdapter;
    AaveV3LendingAdapter public aaveV3LendingAdapter;
    AaveV4LendingAdapter public aaveV4LendingAdapter;
    MorphoBlueLendingAdapter public morphoBlueLendingAdapter;

    MockERC20 public usdc;
    MockERC20WithDecimals public weth;
    MockERC20WithDecimals public rewardToken;
    MockERC20WithDecimals public wellToken;
    MockERC4626 public erc4626Vault;
    MockAaveV3Pool public aaveV3VaultPool;
    WalletLinkRegistry public walletLinkRegistry;
    MockAToken public aaveV3Vault;
    MockCToken public compoundV2Vault;
    MockCompoundV3Comet public compoundV3Market;
    MockLendingAaveV3Pool public aaveV3LendingPool;
    MockAaveV3AddressesProvider public aaveV3AddressesProvider;
    MockAaveV3Oracle public aaveV3Oracle;
    MockERC20 public aaveV3CollateralAToken;
    MockERC20 public aaveV3VariableDebtToken;
    MockLendingAaveV4Spoke public aaveV4Spoke;
    MockAaveV4Oracle public aaveV4Oracle;
    MockLendingMorpho public morpho;
    MockMorphoOracle public morphoOracle;
    MockMerklDistributor public merklDistributor;
    MockMoonwellComptroller public moonwellComptroller;
    MockUniswapV3Router public uniswapV3Router;
    MockAerodromeV2Router public aerodromeV2Router;
    MockAerodromeCLRouter public aerodromeCLRouter;
    MockFeePriceFeed public sequencerFeed;
    MockFeePriceFeed public usdcPriceFeed;
    MockFeePriceFeed public wethPriceFeed;
    MockFeePriceFeed public rewardPriceFeed;
    MockFeePriceFeed public wellPriceFeed;

    bytes public aaveV3Market;
    bytes public aaveV4Market;
    bytes public morphoMarket;

    function setUp() public virtual {
        admin = address(this);
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        feeCollector = makeAddr("feeCollector");

        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20WithDecimals("Wrapped Ether", "WETH", 18);
        rewardToken = new MockERC20WithDecimals("Reward Token", "RWD", 18);
        wellToken = new MockERC20WithDecimals("Moonwell", "WELL", 18);
        erc4626Vault = new MockERC4626(address(usdc), "Mock USDC Vault", "mvUSDC");
        aaveV3VaultPool = new MockAaveV3Pool(address(usdc));
        aaveV3Vault = MockAToken(aaveV3VaultPool.aToken());
        compoundV2Vault = new MockCToken(address(usdc), "Mock Compound USDC", "mcUSDC");
        compoundV3Market = new MockCompoundV3Comet(address(usdc));
        aaveV3LendingPool = new MockLendingAaveV3Pool();
        aaveV3CollateralAToken = new MockERC20("Aave USDC", "aUSDC");
        aaveV3VariableDebtToken = new MockERC20("Aave WETH Debt", "vdWETH");
        aaveV3LendingPool.setReserve(address(usdc), address(aaveV3CollateralAToken), address(0));
        aaveV3LendingPool.setReserve(address(weth), address(0), address(aaveV3VariableDebtToken));
        aaveV3AddressesProvider = MockAaveV3AddressesProvider(address(aaveV3LendingPool.ADDRESSES_PROVIDER()));
        aaveV3Oracle = MockAaveV3Oracle(address(aaveV3AddressesProvider.getPriceOracle()));
        aaveV3Oracle.setAssetPrice(address(usdc), 1e8);
        aaveV3Oracle.setAssetPrice(address(weth), 2000e8);
        aaveV4Spoke = new MockLendingAaveV4Spoke();
        aaveV4Spoke.setReserve(1, address(usdc), 6);
        aaveV4Spoke.setReserve(2, address(weth), 18);
        aaveV4Oracle = MockAaveV4Oracle(address(aaveV4Spoke.ORACLE()));
        aaveV4Oracle.setReservePrice(1, 1e8);
        aaveV4Oracle.setReservePrice(2, 2000e8);
        morpho = new MockLendingMorpho();
        morphoOracle = new MockMorphoOracle();
        morphoOracle.setPrice(5e44);
        merklDistributor = new MockMerklDistributor();
        moonwellComptroller = new MockMoonwellComptroller(wellToken);
        moonwellComptroller.setRewardPerMarket(100e18);
        uniswapV3Router = new MockUniswapV3Router();
        aerodromeV2Router = new MockAerodromeV2Router();
        aerodromeCLRouter = new MockAerodromeCLRouter();

        uint256 timestamp = vm.getBlockTimestamp();
        vm.warp(timestamp + 2 hours);
        timestamp = vm.getBlockTimestamp();
        sequencerFeed = new MockFeePriceFeed(0, 0, timestamp - 2 hours);
        usdcPriceFeed = new MockFeePriceFeed(8, 1e8, timestamp);
        wethPriceFeed = new MockFeePriceFeed(8, 2000e8, timestamp);
        rewardPriceFeed = new MockFeePriceFeed(8, 1e8, timestamp);
        wellPriceFeed = new MockFeePriceFeed(8, 1e8, timestamp);

        factory = new AgentWalletFactory(admin, operator);
        walletImplementation = new AgentWallet(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);
        vaultRegistry = new AdapterRegistry(admin, admin);
        borrowRegistry = new AdapterRegistry(admin, admin);
        vaultFeeTracker = new FeeTracker(admin, feeCollector);
        borrowFeeTracker = new FeeTracker(admin, feeCollector);
        vaultYieldFeeModule = new YieldSeekerYieldFeeModule(vaultFeeTracker, 5000);
        borrowYieldFeeModule = new YieldSeekerYieldFeeModule(borrowFeeTracker, 5000);
        borrowFeeModule = new YieldSeekerBorrowFeeModule(borrowFeeTracker, 200);
        vaultFeeTracker.setFeeModule(YIELD_FEE, vaultYieldFeeModule);
        vaultFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_FEE_BPS})));
        borrowFeeTracker.setFeeModule(YIELD_FEE, borrowYieldFeeModule);
        borrowFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_FEE_BPS})));
        borrowFeeTracker.setFeeModule(BORROW_FEE, borrowFeeModule);
        borrowFeeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: BORROW_FEE_BPS})));
        vaultFeeTracker.setWalletFactory(address(factory));
        borrowFeeTracker.setWalletFactory(address(factory));

        priceOracle = new YieldSeekerPriceOracle(admin, admin, IPriceFeed(address(sequencerFeed)));
        priceOracle.setSource(address(usdc), IPriceFeed(address(usdcPriceFeed)), 1 days);
        priceOracle.setSource(address(weth), IPriceFeed(address(wethPriceFeed)), 1 days);
        priceOracle.setSource(address(rewardToken), IPriceFeed(address(rewardPriceFeed)), 1 days);
        priceOracle.setSource(address(wellToken), IPriceFeed(address(wellPriceFeed)), 1 days);
        swapSellPolicy = new SwapSellPolicy(admin, admin, false);
        swapSellPolicy.addSellableToken(address(rewardToken));
        swapSellPolicy.addSellableToken(address(wellToken));
        vaultSwapPolicy = new YieldSeekerVaultSwapPolicy(swapSellPolicy);
        borrowSwapPolicy = new YieldSeekerBorrowSwapPolicy(swapSellPolicy, priceOracle, BORROW_SWAP_MAX_SLIPPAGE_BPS);

        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, vaultRegistry);
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, borrowRegistry);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, vaultFeeTracker);
        factory.setFeeTracker(BORROW_AGENT_PROFILE, borrowFeeTracker);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, vaultSwapPolicy);
        factory.setSwapPolicy(BORROW_AGENT_PROFILE, borrowSwapPolicy);

        erc4626Adapter = new ERC4626Adapter();
        aaveV3Adapter = new AaveV3Adapter();
        compoundV3Adapter = new CompoundV3Adapter();
        compoundV2Adapter = new CompoundV2Adapter();
        moonwellRewardAdapter = new MoonwellRewardAdapter(address(wellToken));
        merklAdapter = new MerklAdapter();
        uniswapV3SwapAdapter = new UniswapV3SwapAdapter(address(uniswapV3Router));
        aerodromeV2SwapAdapter = new AerodromeV2SwapAdapter(address(aerodromeV2Router), address(0xFACADE));
        aerodromeCLSwapAdapter = new AerodromeCLSwapAdapter(address(aerodromeCLRouter));
        walletLinkRegistry = new WalletLinkRegistry();
        agentTransferAdapter = new AgentTransferAdapter(walletLinkRegistry);
        aaveV3LendingAdapter = new AaveV3LendingAdapter();
        aaveV4LendingAdapter = new AaveV4LendingAdapter();
        morphoBlueLendingAdapter = new MorphoBlueLendingAdapter();

        _registerTarget(vaultRegistry, address(erc4626Vault), address(erc4626Adapter));
        _registerTarget(vaultRegistry, address(aaveV3Vault), address(aaveV3Adapter));
        _registerTarget(vaultRegistry, address(compoundV3Market), address(compoundV3Adapter));
        _registerTarget(vaultRegistry, address(compoundV2Vault), address(compoundV2Adapter));
        _registerTarget(vaultRegistry, address(moonwellComptroller), address(moonwellRewardAdapter));
        _registerTarget(vaultRegistry, address(merklDistributor), address(merklAdapter));
        _registerTarget(vaultRegistry, address(uniswapV3Router), address(uniswapV3SwapAdapter));
        _registerTarget(vaultRegistry, address(aerodromeV2Router), address(aerodromeV2SwapAdapter));
        _registerTarget(vaultRegistry, address(aerodromeCLRouter), address(aerodromeCLSwapAdapter));
        _registerTarget(vaultRegistry, address(walletLinkRegistry), address(agentTransferAdapter));

        aaveV3Market = abi.encode(address(aaveV3LendingPool), address(usdc), address(weth), uint8(0));
        aaveV4Market = abi.encode(address(aaveV4Spoke), uint256(1), uint256(2));
        IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({loanToken: address(weth), collateralToken: address(usdc), oracle: address(morphoOracle), irm: address(0x1), lltv: 0.8e18});
        morphoMarket = abi.encode(address(morpho), params);
        _registerTarget(borrowRegistry, aaveV3LendingAdapter.marketTarget(aaveV3Market), address(aaveV3LendingAdapter));
        _registerTarget(borrowRegistry, aaveV4LendingAdapter.marketTarget(aaveV4Market), address(aaveV4LendingAdapter));
        _registerTarget(borrowRegistry, morphoBlueLendingAdapter.marketTarget(morphoMarket), address(morphoBlueLendingAdapter));
        _registerTarget(borrowRegistry, address(merklDistributor), address(merklAdapter));
        _registerTarget(borrowRegistry, address(uniswapV3Router), address(uniswapV3SwapAdapter));
        _registerTarget(borrowRegistry, address(aerodromeV2Router), address(aerodromeV2SwapAdapter));
        _registerTarget(borrowRegistry, address(aerodromeCLRouter), address(aerodromeCLSwapAdapter));
        _registerTarget(borrowRegistry, address(walletLinkRegistry), address(agentTransferAdapter));

        _fund(address(usdc), address(merklDistributor), 1_000_000e6);
        _fund(address(rewardToken), address(merklDistributor), 1_000_000e18);
        _fund(address(wellToken), address(moonwellComptroller), 1_000_000e18);
        _fund(address(usdc), address(uniswapV3Router), 1_000_000e6);
        _fund(address(weth), address(uniswapV3Router), 1_000_000e18);
        _fund(address(rewardToken), address(uniswapV3Router), 1_000_000e18);
        _fund(address(wellToken), address(uniswapV3Router), 1_000_000e18);
        _fund(address(usdc), address(aerodromeV2Router), 1_000_000e6);
        _fund(address(weth), address(aerodromeV2Router), 1_000_000e18);
        _fund(address(rewardToken), address(aerodromeV2Router), 1_000_000e18);
        _fund(address(wellToken), address(aerodromeV2Router), 1_000_000e18);
        _fund(address(usdc), address(aerodromeCLRouter), 1_000_000e6);
        _fund(address(weth), address(aerodromeCLRouter), 1_000_000e18);
        _fund(address(rewardToken), address(aerodromeCLRouter), 1_000_000e18);
        _fund(address(wellToken), address(aerodromeCLRouter), 1_000_000e18);
    }

    function _createVaultWallet(address walletOwner, uint256 index) internal returns (AgentWallet wallet) {
        FeePlanChoice[] memory feePlans = new FeePlanChoice[](0);
        return _createVaultWallet(walletOwner, index, feePlans);
    }

    function _createVaultWallet(address walletOwner, uint256 index, FeePlanChoice[] memory feePlans) internal returns (AgentWallet wallet) {
        vm.prank(operator);
        wallet = AgentWallet(payable(address(factory.createAgentWallet(walletOwner, index, address(usdc), VAULT_AGENT_PROFILE, feePlans))));
    }

    function _createBorrowWallet(address walletOwner, uint256 index) internal returns (AgentWallet wallet) {
        FeePlanChoice[] memory feePlans = new FeePlanChoice[](0);
        return _createBorrowWallet(walletOwner, index, feePlans);
    }

    function _createBorrowWallet(address walletOwner, uint256 index, FeePlanChoice[] memory feePlans) internal returns (AgentWallet wallet) {
        vm.prank(operator);
        wallet = AgentWallet(payable(address(factory.createAgentWallet(walletOwner, index, address(usdc), BORROW_AGENT_PROFILE, feePlans))));
    }

    function _execute(AgentWallet wallet, address adapter, address target, bytes memory data) internal returns (bytes memory result) {
        vm.prank(operator);
        result = wallet.executeViaAdapter(adapter, target, data);
    }

    function _executeExpectRevert(AgentWallet wallet, address adapter, address target, bytes memory data, bytes memory innerError) internal {
        bytes memory expectedError = abi.encodeWithSelector(AdapterExecutionFailed.selector, innerError);
        vm.expectRevert(expectedError);
        vm.prank(operator);
        wallet.executeViaAdapter(adapter, target, data);
    }

    function _registerTarget(AdapterRegistry registry, address target, address adapter) internal {
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
    }

    function _fund(address token, address recipient, uint256 amount) internal {
        IMintableToken(token).mint(recipient, amount);
    }

    function _fundWallet(AgentWallet wallet, address token, uint256 amount) internal {
        _fund(token, address(wallet), amount);
    }

    function _feesCollected(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(feeCollector);
    }
}
