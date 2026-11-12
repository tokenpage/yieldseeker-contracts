// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerPriceOracle} from "../../../src/PriceOracle.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerAaveV3LendingAdapter as AaveV3LendingAdapter} from "../../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../../../src/adapters/AaveV4LendingAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../../../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerAgentTransferAdapter as AgentTransferAdapter} from "../../../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../../../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../../../src/adapters/MerklAdapter.sol";
import {YieldSeekerMoonwellRewardAdapter as MoonwellRewardAdapter} from "../../../src/adapters/MoonwellRewardAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter as MorphoBlueLendingAdapter} from "../../../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKAerodromeCLSwapAdapter} from "../../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {IMorphoBlue, IMorphoOracle} from "../../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice} from "../../../src/fees/FeeTracker.sol";
import {YIELD_FEE} from "../../../src/fees/YieldFeeModule.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockAToken} from "../../mocks/MockAaveV3.sol";
import {MockCToken} from "../../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../../mocks/MockCompoundV3.sol";
import {MockERC20, MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockFeePriceFeed} from "../../mocks/MockFeePriceFeed.sol";
import {MockAerodromeCLRouter, MockAerodromeV2Router, MockMerklDistributor, MockMoonwellComptroller, MockUniswapV3Router} from "../../mocks/MockIntegrationMocks.sol";
import {MockLendingAaveV3Pool, MockLendingAaveV4Spoke, MockMorphoOracle} from "../../mocks/MockLendingMarkets.sol";
import {OperatorHostileRouter, OperatorHostileToken, OperatorHostileVault, OperatorMockEntryPoint, OperatorMorphoBlueMarket, OperatorThiefReceiver} from "./mocks/CompromisedOperatorMocks.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IOperatorEntryPoint {
    function depositTo(address account) external payable;
    function balanceOf(address account) external view returns (uint256);
    function getNonce(address account, uint192 key) external view returns (uint256);
    function withdrawTo(address payable recipient, uint256 amount) external;
}

interface IWalletV06Validation {
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256);
}

interface IWalletPackedValidation {
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256);
}

struct CompromisedOperatorSetup {
    address ownerA;
    address ownerB;
    address operator;
    uint256 operatorKey;
    address thief;
    address feeCollector;
    AgentWallet ownerAVault;
    AgentWallet ownerABorrow;
    AgentWallet ownerAWethSink;
    AgentWallet ownerAMorpho;
    AgentWallet ownerBVault;
    AgentWallet ownerBBorrow;
    AgentWallet thiefVault;
    AgentWallet thiefBorrow;
    AgentWalletFactory factory;
    MockERC20 usdc;
    MockERC20WithDecimals weth;
    MockERC20WithDecimals rewardToken;
    MockERC20WithDecimals wellToken;
    MockERC4626 erc4626Vault;
    MockAToken aaveV3Vault;
    MockCToken compoundV2Vault;
    MockCompoundV3Comet compoundV3Market;
    MockERC20 aaveV3CollateralAToken;
    MockERC20 aaveV3VariableDebtToken;
    AaveV3Adapter aaveV3Adapter;
    CompoundV2Adapter compoundV2Adapter;
    CompoundV3Adapter compoundV3Adapter;
    ERC4626Adapter erc4626Adapter;
    MerklAdapter merklAdapter;
    MoonwellRewardAdapter moonwellRewardAdapter;
    UniswapV3SwapAdapter uniswapV3SwapAdapter;
    AerodromeV2SwapAdapter aerodromeV2SwapAdapter;
    AerodromeCLSwapAdapter aerodromeCLSwapAdapter;
    AgentTransferAdapter agentTransferAdapter;
    AaveV3LendingAdapter aaveV3LendingAdapter;
    AaveV4LendingAdapter aaveV4LendingAdapter;
    MorphoBlueLendingAdapter morphoBlueLendingAdapter;
    MockLendingAaveV3Pool aaveV3LendingPool;
    MockLendingAaveV4Spoke aaveV4Spoke;
    OperatorMorphoBlueMarket morpho;
    MockMorphoOracle morphoOracle;
    MockMerklDistributor merklDistributor;
    MockMoonwellComptroller moonwellComptroller;
    MockUniswapV3Router uniswapV3Router;
    MockAerodromeV2Router aerodromeV2Router;
    MockAerodromeCLRouter aerodromeCLRouter;
    MockFeePriceFeed usdcPriceFeed;
    MockFeePriceFeed wethPriceFeed;
    MockFeePriceFeed rewardPriceFeed;
    MockFeePriceFeed wellPriceFeed;
    YieldSeekerPriceOracle priceOracle;
    bytes aaveV3Market;
    bytes aaveV4Market;
    bytes morphoMarket;
    OperatorHostileToken hostileToken;
    OperatorHostileRouter hostileRouter;
    OperatorHostileVault hostileVault;
    OperatorThiefReceiver thiefReceiver;
}

struct MorphoLifecycleSetup {
    AgentWallet wallet;
    AgentWallet source;
    uint256 collateralAmount;
    uint256 elapsed;
    uint256 rounds;
    bool requireSuccess;
}

struct MorphoAccrualSnapshot {
    uint256 debt;
    uint256 fee;
    uint256 costs;
}

contract CompromisedOperatorHandler is Test {
    using MessageHashUtils for bytes32;

    address private constant ENTRY_POINT_V06 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 private constant DEBT_BUFFER_BPS = 300;
    bytes32 private constant VAULT_AGENT_PROFILE = keccak256("vault");
    bytes32 private constant BORROW_AGENT_PROFILE = keccak256("borrow");
    address private constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint256 private constant USDC_UNIT = 1e6;
    uint256 private constant WETH_UNIT = 1e18;
    uint256 private constant ETH_WALLET_BALANCE = 0.02 ether;
    uint256 private constant ENTRY_POINT_DEPOSIT = 0.05 ether;

    address public immutable ownerA;
    address public immutable ownerB;
    address public immutable operator;
    uint256 private immutable _operatorKey;
    address public immutable thief;
    address public immutable feeCollector;
    AgentWallet public immutable ownerAMorpho;
    AgentWalletFactory public immutable factory;
    MockERC20 public immutable usdc;
    MockERC20WithDecimals public immutable weth;
    MockERC20WithDecimals public immutable rewardToken;
    MockERC20WithDecimals public immutable wellToken;
    MockERC4626 public immutable erc4626Vault;
    MockAToken public immutable aaveV3Vault;
    MockCToken public immutable compoundV2Vault;
    MockCompoundV3Comet public immutable compoundV3Market;
    MockERC20 public immutable aaveV3CollateralAToken;
    MockERC20 public immutable aaveV3VariableDebtToken;
    AaveV3Adapter public immutable aaveV3Adapter;
    CompoundV2Adapter public immutable compoundV2Adapter;
    CompoundV3Adapter public immutable compoundV3Adapter;
    ERC4626Adapter public immutable erc4626Adapter;
    MerklAdapter public immutable merklAdapter;
    MoonwellRewardAdapter public immutable moonwellRewardAdapter;
    UniswapV3SwapAdapter public immutable uniswapV3SwapAdapter;
    AerodromeV2SwapAdapter public immutable aerodromeV2SwapAdapter;
    AerodromeCLSwapAdapter public immutable aerodromeCLSwapAdapter;
    AgentTransferAdapter public immutable agentTransferAdapter;
    AaveV3LendingAdapter public immutable aaveV3LendingAdapter;
    AaveV4LendingAdapter public immutable aaveV4LendingAdapter;
    MorphoBlueLendingAdapter public immutable morphoBlueLendingAdapter;
    MockLendingAaveV3Pool public immutable aaveV3LendingPool;
    MockLendingAaveV4Spoke public immutable aaveV4Spoke;
    OperatorMorphoBlueMarket public immutable morpho;
    MockMorphoOracle public immutable morphoOracle;
    MockMerklDistributor public immutable merklDistributor;
    MockMoonwellComptroller public immutable moonwellComptroller;
    MockUniswapV3Router public immutable uniswapV3Router;
    MockAerodromeV2Router public immutable aerodromeV2Router;
    MockAerodromeCLRouter public immutable aerodromeCLRouter;
    MockFeePriceFeed public immutable usdcPriceFeed;
    MockFeePriceFeed public immutable wethPriceFeed;
    MockFeePriceFeed public immutable rewardPriceFeed;
    MockFeePriceFeed public immutable wellPriceFeed;
    YieldSeekerPriceOracle public immutable priceOracle;
    bytes public aaveV3Market;
    bytes public aaveV4Market;
    bytes public morphoMarket;
    OperatorHostileToken public immutable hostileToken;
    OperatorHostileRouter public immutable hostileRouter;
    OperatorHostileVault public immutable hostileVault;
    OperatorThiefReceiver public immutable thiefReceiver;
    AgentWallet public immutable thiefVault;
    AgentWallet public immutable thiefBorrow;

    uint256 public initialLiquidatorWeth;
    uint256 public liquidationWethSpent;
    uint256 public liquidationCollateralReceived;
    uint256 public liquidationBonusValue;
    uint256 public liquidationRepaidValue;
    uint256 public liquidationSuccesses;
    uint256 public morphoInterestBudget;
    uint256 public morphoBorrowFeeGrowth;
    AgentWallet[] private _ownerAWallets;
    AgentWallet[] private _ownerBWallets;
    AgentWallet[] private _thiefWallets;
    mapping(address owner => uint256 value) public initialDeposits;
    mapping(address wallet => uint256 amount) private _debtBufferBudget;
    mapping(address wallet => uint256 amount) private _trackedProtocolCosts;
    mapping(address owner => uint256 value) public withdrawnValue;
    mapping(address owner => uint256 value) public feesPaidByOwner;
    mapping(address owner => uint256 value) public acceptedLossBudget;
    mapping(address wallet => uint256 amount) private _merklClaimed;
    mapping(address wallet => uint256 amount) public expectedWalletEth;
    mapping(address wallet => uint256 amount) public expectedEntryPointDeposit;
    mapping(address adapter => uint256 amount) public adapterAttempts;
    mapping(address adapter => uint256 amount) public adapterBlocks;

    uint256 public vaultWorkflowAttempts;
    uint256 public vaultWorkflowBlocks;
    uint256 public rewardWorkflowAttempts;
    uint256 public rewardWorkflowBlocks;
    uint256 public lendingWorkflowAttempts;
    uint256 public lendingWorkflowBlocks;
    uint256 public swapWorkflowAttempts;
    uint256 public swapWorkflowBlocks;
    uint256 public transferWorkflowAttempts;
    uint256 public transferWorkflowBlocks;
    uint256 public arbitraryCallAttempts;
    uint256 public arbitraryCallBlocks;
    uint256 public privilegedCallAttempts;
    uint256 public privilegedCallBlocks;
    uint256 public userOpAttempts;
    uint256 public userOpWithoutPaymasterBlocks;
    uint256 public sponsoredUserOpSuccesses;
    uint256 public unregisteredTargetAttempts;
    uint256 public unregisteredTargetBlocks;
    uint256 public hostileTokenAttempts;
    uint256 public hostileTokenBlocks;
    uint256 public factoryWalletAttempts;
    uint256 public factoryWalletBlocks;
    uint256 public ownerWithdrawAttempts;
    uint256 public ownerWithdrawSuccesses;
    uint256 public ownerBlocklistCalls;
    uint256 public crossOwnerTransferAttempts;
    uint256 public crossOwnerTransferBlocks;
    uint256 public walletEthSpendAttempts;
    uint256 public walletEthSpendBlocks;
    uint256 public entryPointSpendAttempts;
    uint256 public entryPointSpendBlocks;
    uint256 public priceAndTimeMoves;
    uint256 public liquidationAttempts;
    uint256 public liquidationBlocks;

    uint256 private _ownerWalletIndexA = 20;
    uint256 private _ownerWalletIndexB = 20;
    uint256 private _thiefWalletIndex = 20;

    constructor(CompromisedOperatorSetup memory setup) {
        ownerA = setup.ownerA;
        ownerB = setup.ownerB;
        operator = setup.operator;
        _operatorKey = setup.operatorKey;
        thief = setup.thief;
        feeCollector = setup.feeCollector;
        factory = setup.factory;
        usdc = setup.usdc;
        weth = setup.weth;
        initialLiquidatorWeth = weth.balanceOf(thief);
        rewardToken = setup.rewardToken;
        wellToken = setup.wellToken;
        erc4626Vault = setup.erc4626Vault;
        aaveV3Vault = setup.aaveV3Vault;
        compoundV2Vault = setup.compoundV2Vault;
        compoundV3Market = setup.compoundV3Market;
        aaveV3CollateralAToken = setup.aaveV3CollateralAToken;
        aaveV3VariableDebtToken = setup.aaveV3VariableDebtToken;
        aaveV3Adapter = setup.aaveV3Adapter;
        compoundV2Adapter = setup.compoundV2Adapter;
        compoundV3Adapter = setup.compoundV3Adapter;
        erc4626Adapter = setup.erc4626Adapter;
        merklAdapter = setup.merklAdapter;
        moonwellRewardAdapter = setup.moonwellRewardAdapter;
        uniswapV3SwapAdapter = setup.uniswapV3SwapAdapter;
        aerodromeV2SwapAdapter = setup.aerodromeV2SwapAdapter;
        aerodromeCLSwapAdapter = setup.aerodromeCLSwapAdapter;
        agentTransferAdapter = setup.agentTransferAdapter;
        aaveV3LendingAdapter = setup.aaveV3LendingAdapter;
        aaveV4LendingAdapter = setup.aaveV4LendingAdapter;
        morphoBlueLendingAdapter = setup.morphoBlueLendingAdapter;
        aaveV3LendingPool = setup.aaveV3LendingPool;
        aaveV4Spoke = setup.aaveV4Spoke;
        morpho = setup.morpho;
        morphoOracle = setup.morphoOracle;
        merklDistributor = setup.merklDistributor;
        moonwellComptroller = setup.moonwellComptroller;
        uniswapV3Router = setup.uniswapV3Router;
        aerodromeV2Router = setup.aerodromeV2Router;
        aerodromeCLRouter = setup.aerodromeCLRouter;
        usdcPriceFeed = setup.usdcPriceFeed;
        wethPriceFeed = setup.wethPriceFeed;
        rewardPriceFeed = setup.rewardPriceFeed;
        wellPriceFeed = setup.wellPriceFeed;
        priceOracle = setup.priceOracle;
        aaveV3Market = setup.aaveV3Market;
        aaveV4Market = setup.aaveV4Market;
        morphoMarket = setup.morphoMarket;
        hostileToken = setup.hostileToken;
        hostileRouter = setup.hostileRouter;
        hostileVault = setup.hostileVault;
        thiefReceiver = setup.thiefReceiver;
        thiefVault = setup.thiefVault;
        thiefBorrow = setup.thiefBorrow;

        ownerAMorpho = setup.ownerAMorpho;
        _ownerAWallets.push(setup.ownerAVault);
        _ownerAWallets.push(setup.ownerABorrow);
        _ownerAWallets.push(setup.ownerAWethSink);
        _ownerAWallets.push(setup.ownerAMorpho);
        _ownerBWallets.push(setup.ownerBVault);
        _ownerBWallets.push(setup.ownerBBorrow);
        _thiefWallets.push(setup.thiefVault);
        _thiefWallets.push(setup.thiefBorrow);

        expectedWalletEth[address(setup.ownerAVault)] = address(setup.ownerAVault).balance;
        expectedWalletEth[address(setup.ownerABorrow)] = address(setup.ownerABorrow).balance;
        expectedWalletEth[address(setup.ownerAWethSink)] = address(setup.ownerAWethSink).balance;
        expectedWalletEth[address(setup.ownerAMorpho)] = address(setup.ownerAMorpho).balance;
        expectedWalletEth[address(setup.ownerBVault)] = address(setup.ownerBVault).balance;
        expectedWalletEth[address(setup.ownerBBorrow)] = address(setup.ownerBBorrow).balance;
        expectedEntryPointDeposit[address(setup.ownerAVault)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerAVault));
        expectedEntryPointDeposit[address(setup.ownerABorrow)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerABorrow));
        expectedEntryPointDeposit[address(setup.ownerAWethSink)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerAWethSink));
        expectedEntryPointDeposit[address(setup.ownerBVault)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerBVault));
        expectedEntryPointDeposit[address(setup.ownerBBorrow)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerBBorrow));
        expectedEntryPointDeposit[address(setup.ownerAMorpho)] = IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(setup.ownerAMorpho));
        initialDeposits[ownerA] = 20_000 * USDC_UNIT;
        initialDeposits[ownerB] = 10_000 * USDC_UNIT;
        uint256 initialCostsA = _protocolCosts(_ownerAWallets[1]);
        uint256 initialCostsB = _protocolCosts(_ownerBWallets[1]);
        uint256 initialMorphoCosts = _protocolCosts(ownerAMorpho);
        _trackedProtocolCosts[address(_ownerAWallets[1])] = initialCostsA;
        _trackedProtocolCosts[address(_ownerBWallets[1])] = initialCostsB;
        _trackedProtocolCosts[address(ownerAMorpho)] = initialMorphoCosts;
        acceptedLossBudget[ownerA] += initialCostsA + initialMorphoCosts;
        acceptedLossBudget[ownerB] += initialCostsB;
        _updateDebtBufferBudget(_ownerAWallets[1]);
        _updateDebtBufferBudget(_ownerBWallets[1]);
        _updateDebtBufferBudget(ownerAMorpho);
    }

    function ownerWalletCount(address walletOwner) external view returns (uint256) {
        return walletOwner == ownerA ? _ownerAWallets.length : _ownerBWallets.length;
    }

    function ownerWalletAt(address walletOwner, uint256 index) external view returns (AgentWallet) {
        return walletOwner == ownerA ? _ownerAWallets[index] : _ownerBWallets[index];
    }

    function thiefWalletCount() external view returns (uint256) {
        return _thiefWallets.length;
    }

    function thiefWalletAt(uint256 index) external view returns (AgentWallet) {
        return _thiefWallets[index];
    }

    function ownerValue(address walletOwner) external view returns (uint256) {
        return _ownerValue(walletOwner);
    }

    function operatorRunsEveryVaultAdapter(uint96 amountSeed) external {
        vaultWorkflowAttempts++;
        AgentWallet wallet = _ownerAWallets[0];
        _vaultRoundTrip(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (uint256(0))), amountSeed);
        _vaultRoundTrip(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (uint256(0))), amountSeed);
        _vaultRoundTrip(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.deposit, (uint256(0))), amountSeed);
        _vaultRoundTrip(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (uint256(0))), amountSeed);
        _operatorVaultBatch(wallet, amountSeed);
        transferWorkflowAttempts++;
        (bool success,) = _operatorExecute(wallet, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(wallet), 1)));
        if (!success) transferWorkflowBlocks++;
    }

    function operatorClaimsAndDumpsRewards(uint96 amountSeed) external {
        rewardWorkflowAttempts++;
        AgentWallet vaultWallet = _ownerAWallets[0];
        AgentWallet borrowWallet = _ownerAWallets[1];
        uint256 rewardIncrement = bound(amountSeed, 1e18, 5e18);
        _claimMerkl(vaultWallet, rewardIncrement);
        _claimMerkl(borrowWallet, rewardIncrement);
        _claimMoonwell(vaultWallet);
        _claimMoonwellWithThiefHolder(vaultWallet);
        _sellRewardOnAllDexes(vaultWallet, address(rewardToken), amountSeed);
        _sellRewardOnAllDexes(borrowWallet, address(rewardToken), amountSeed);
        _sellRewardOnOneDex(vaultWallet, address(wellToken), 0, amountSeed);
        _tryUnregisteredRewardClaim(vaultWallet);
    }

    function operatorRunsEveryBorrowAdapter(uint96 amountSeed) external {
        lendingWorkflowAttempts++;
        AgentWallet wallet = _ownerAWallets[1];
        _exerciseAaveV3Lending(wallet, amountSeed);
        _exerciseAaveV4Lending(wallet, amountSeed);
        _exerciseMorphoLending(wallet, amountSeed);
        _tryBorrowSwapAtOracleFloor(wallet);
        _runMorphoLiquidationLifecycle(MorphoLifecycleSetup({wallet: ownerAMorpho, source: _ownerAWallets[0], collateralAmount: USDC_UNIT, elapsed: 1 hours, rounds: 1, requireSuccess: false}));
        _tryLiquidation(wallet);
    }

    function operatorBlocksAndAttemptsEveryForbiddenPath(uint8 walletChoice, uint96 amountSeed) external {
        AgentWallet wallet = _ownerWallet(walletChoice);
        _tryUnregisteredTargets(_ownerAWallets[0]);
        _tryUnregisteredTargets(_ownerAWallets[1]);
        _tryHostileToken(wallet);
        _tryDirectArbitraryCalls(wallet);
        _tryPrivilegedWalletCalls(wallet);
        _tryUserOps(wallet, amountSeed);
        _tryWalletEthSpend(wallet);
        _tryEntryPointSpend(wallet);
        _tryCrossOwnerTransfers();
        _tryUnregisteredFactoryCreate();
    }

    function honestOwnersWithdrawAndBlock(uint96 amountSeed, bool blockIt) external {
        _ownerWithdrawSingle(_ownerAWallets[0], ownerA, amountSeed);
        _ownerWithdrawAll(_ownerAWallets[1], ownerA, address(usdc));
        _ownerWithdrawBatch(_ownerAWallets[1], ownerA, amountSeed);
        _ownerWithdrawAllBatch(_ownerBWallets[1], ownerB);
        _ownerBlocklists(_ownerAWallets[0], ownerA, blockIt);
        _ownerBlocklists(_ownerBWallets[1], ownerB, !blockIt);
    }

    function operatorCreatesOwnerAndThiefWallets(uint8 choiceSeed) external {
        factoryWalletAttempts++;
        bool useOwnerA = choiceSeed % 2 == 0;
        address selectedOwner = useOwnerA ? ownerA : ownerB;
        uint256 ownerCount = useOwnerA ? _ownerAWallets.length : _ownerBWallets.length;
        uint256 index = useOwnerA ? _ownerWalletIndexA : _ownerWalletIndexB;
        if (ownerCount >= 6) index--;
        bytes32 profile = (choiceSeed & 2) == 0 ? VAULT_AGENT_PROFILE : BORROW_AGENT_PROFILE;
        address baseAsset = (choiceSeed & 4) == 0 ? address(usdc) : address(weth);
        FeePlanChoice[] memory plans = _feePlans(profile);
        vm.prank(operator);
        (bool success, bytes memory result) = address(factory).call(abi.encodeCall(factory.createAgentWallet, (selectedOwner, index, baseAsset, profile, plans)));
        if (success) {
            AgentWallet created = AgentWallet(payable(abi.decode(result, (address))));
            if (useOwnerA) {
                _ownerAWallets.push(created);
                _ownerWalletIndexA++;
            } else {
                _ownerBWallets.push(created);
                _ownerWalletIndexB++;
            }
            expectedWalletEth[address(created)] = 0;
            expectedEntryPointDeposit[address(created)] = 0;
            _moveSupportedAssetToNewWallet(selectedOwner, created, baseAsset);
        } else {
            factoryWalletBlocks++;
        }

        factoryWalletAttempts++;
        uint256 thiefIndex = _thiefWallets.length >= 6 ? _thiefWalletIndex - 1 : _thiefWalletIndex;
        bytes32 thiefProfile = (choiceSeed & 1) == 0 ? VAULT_AGENT_PROFILE : BORROW_AGENT_PROFILE;
        vm.prank(operator);
        (success, result) = address(factory).call(abi.encodeCall(factory.createAgentWallet, (thief, thiefIndex, address(usdc), thiefProfile, _feePlans(thiefProfile))));
        if (success) {
            AgentWallet createdThiefWallet = AgentWallet(payable(abi.decode(result, (address))));
            _thiefWallets.push(createdThiefWallet);
            _thiefWalletIndex++;
        } else {
            factoryWalletBlocks++;
        }
    }

    function operatorMovesTimeAndPrices(uint32 elapsedSeed, uint32 priceSeed) external {
        vm.warp(block.timestamp + bound(elapsedSeed, 1, 1 hours));
        int256 marketPrice = priceSeed % 2 == 0 ? int256(1_999e8) : int256(2_001e8);
        uint256 now_ = block.timestamp;
        wethPriceFeed.setPrice(marketPrice, now_);
        usdcPriceFeed.setPrice(1e8, now_);
        rewardPriceFeed.setPrice(1e8, now_);
        wellPriceFeed.setPrice(1e8, now_);
        aaveV3LendingPool.setAssetPrice(address(weth), uint256(marketPrice));
        aaveV4Spoke.setReservePrice(2, uint256(marketPrice));
        morphoOracle.setPrice(Math.mulDiv(5e44, 2_000e8, uint256(marketPrice)));
        _accrueMorphoAndTrackInterest();
        for (uint256 i; i < _ownerAWallets.length; i++) {
            if (_ownerAWallets[i].agentProfile() == BORROW_AGENT_PROFILE) _refreshBorrowBudgets(_ownerAWallets[i]);
        }
        for (uint256 i; i < _ownerBWallets.length; i++) {
            if (_ownerBWallets[i].agentProfile() == BORROW_AGENT_PROFILE) _refreshBorrowBudgets(_ownerBWallets[i]);
        }
        priceAndTimeMoves++;
    }

    function runWorstCase(uint8 routeSeed) external {
        AgentWallet vaultWallet = _ownerAWallets[0];
        _runWorstCaseVaultFees(vaultWallet);
        _runMorphoLiquidationLifecycle(MorphoLifecycleSetup({wallet: ownerAMorpho, source: vaultWallet, collateralAmount: 1_000 * USDC_UNIT, elapsed: 365 days, rounds: 3, requireSuccess: true}));
        _runWorstCaseBorrowSwaps();
        _runWorstCaseRewardDumps(vaultWallet, routeSeed);
    }

    function _runWorstCaseVaultFees(AgentWallet vaultWallet) private {
        erc4626Vault.setRedeemFee(100);
        for (uint256 i; i < 8; i++) {
            uint256 beforeValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
            uint256 amount = USDC_UNIT;
            assertGe(usdc.balanceOf(address(vaultWallet)), amount);
            uint256 sharesBefore = erc4626Vault.balanceOf(address(vaultWallet));
            (bool deposited,) = _operatorExecute(vaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (amount)));
            assertTrue(deposited);
            uint256 shares = erc4626Vault.balanceOf(address(vaultWallet)) - sharesBefore;
            assertGt(shares, 0);
            (bool withdrew,) = _operatorExecute(vaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (shares)));
            assertTrue(withdrew);
            uint256 afterValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
            uint256 loss = beforeValue > afterValue ? beforeValue - afterValue : 0;
            uint256 feeBound = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil) + 1;
            assertLe(loss, feeBound);
            acceptedLossBudget[ownerA] += feeBound;
        }
        erc4626Vault.setRedeemFee(0);
    }

    function _runWorstCaseBorrowSwaps() private {
        AgentWallet vaultWallet = _ownerAWallets[0];
        AgentWallet borrowWallet = _ownerAWallets[1];
        AgentWallet sinkWallet = _ownerAWallets[2];
        for (uint256 i; i < 8; i++) {
            uint256 beforeValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
            uint256 amount = USDC_UNIT;
            if (usdc.balanceOf(address(borrowWallet)) < amount) _operatorTransfer(vaultWallet, borrowWallet, address(usdc), amount);
            bool swapped = _tryBorrowSwapAtOracleFloor(borrowWallet, amount);
            assertTrue(swapped);
            uint256 bought = weth.balanceOf(address(borrowWallet));
            assertGt(bought, 0);
            _operatorTransfer(borrowWallet, sinkWallet, address(weth), bought);
            uint256 afterValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
            uint256 loss = beforeValue > afterValue ? beforeValue - afterValue : 0;
            uint256 boundLoss = Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);
            assertLe(loss, boundLoss);
            acceptedLossBudget[ownerA] += boundLoss;
        }
        _tryBorrowSwapAboveDebtCap(borrowWallet);
    }

    function _runWorstCaseRewardDumps(AgentWallet vaultWallet, uint8 routeSeed) private {
        uint256 rewardAmount = 10e18;
        uint8 rewardDex = routeSeed % 3;
        uint8 wellDex = uint8((uint256(rewardDex) + 1) % 3);
        _claimMerkl(vaultWallet, rewardAmount);
        _claimMoonwell(vaultWallet);
        _dumpAllReward(vaultWallet, address(rewardToken), rewardDex);
        _dumpAllReward(vaultWallet, address(wellToken), wellDex);
    }

    function assertOwnerConservation() external view {
        _assertOwnerConservation(ownerA);
        _assertOwnerConservation(ownerB);
    }

    function assertWalletEthAndEntryPointDeposits() external view {
        _assertWalletEthAndEntryPointDeposits(ownerA);
        _assertWalletEthAndEntryPointDeposits(ownerB);
    }

    function assertNoThiefAssetsOrPositions() external view {
        assertEq(hostileRouter.reached(), false);
        assertEq(hostileVault.reached(), false);
        assertEq(hostileToken.balanceOf(thief), 0);
        assertEq(usdc.balanceOf(thief), liquidationCollateralReceived);
        assertEq(weth.balanceOf(thief) + liquidationWethSpent, initialLiquidatorWeth);
        assertLe(liquidationBonusValue, Math.mulDiv(liquidationRepaidValue, 440, 10_000, Math.Rounding.Ceil) + liquidationSuccesses);
        for (uint256 i; i < _thiefWallets.length; i++) {
            _assertNoOwnerAssets(address(_thiefWallets[i]));
        }
        _assertNoPositions(thief);
        _assertNoOwnerAssets(operator);
        _assertNoOwnerAssets(address(hostileRouter));
        _assertNoOwnerAssets(address(hostileVault));
        _assertNoOwnerAssets(address(hostileToken));
        _assertNoOwnerAssets(address(thiefReceiver));
    }

    function assertAllWorkflowCounts() external view {
        assertGt(vaultWorkflowAttempts, 0);
        assertGt(vaultWorkflowBlocks, 0);
        assertGt(rewardWorkflowAttempts, 0);
        assertGt(rewardWorkflowBlocks, 0);
        assertGt(lendingWorkflowAttempts, 0);
        assertGt(lendingWorkflowBlocks, 0);
        assertGt(swapWorkflowAttempts, 0);
        assertGt(swapWorkflowBlocks, 0);
        assertGt(transferWorkflowAttempts, 0);
        assertGt(transferWorkflowBlocks, 0);
        assertGt(arbitraryCallAttempts, 0);
        assertGt(arbitraryCallBlocks, 0);
        assertGt(privilegedCallAttempts, 0);
        assertGt(privilegedCallBlocks, 0);
        assertGt(userOpAttempts, 0);
        assertGt(userOpWithoutPaymasterBlocks, 0);
        assertGt(sponsoredUserOpSuccesses, 0);
        assertGt(unregisteredTargetAttempts, 0);
        assertGt(unregisteredTargetBlocks, 0);
        assertGt(hostileTokenAttempts, 0);
        assertGt(hostileTokenBlocks, 0);
        assertGt(factoryWalletAttempts, 0);
        assertGt(ownerWithdrawAttempts, 0);
        assertGt(ownerWithdrawSuccesses, 0);
        assertGt(ownerBlocklistCalls, 0);
        assertGt(crossOwnerTransferAttempts, 0);
        assertGt(crossOwnerTransferBlocks, 0);
        assertGt(walletEthSpendAttempts, 0);
        assertGt(walletEthSpendBlocks, 0);
        assertGt(entryPointSpendAttempts, 0);
        assertGt(entryPointSpendBlocks, 0);
        assertGt(priceAndTimeMoves, 0);
        assertGt(factoryWalletBlocks, 0);
        assertGt(liquidationAttempts, 0);
        assertGt(liquidationSuccesses, 0);
        assertGt(liquidationBlocks, 0);
        _assertAdapterAttempts(address(erc4626Adapter));
        _assertAdapterAttempts(address(aaveV3Adapter));
        _assertAdapterAttempts(address(compoundV2Adapter));
        _assertAdapterAttempts(address(compoundV3Adapter));
        _assertAdapterAttempts(address(merklAdapter));
        _assertAdapterAttempts(address(moonwellRewardAdapter));
        _assertAdapterAttempts(address(uniswapV3SwapAdapter));
        _assertAdapterAttempts(address(aerodromeV2SwapAdapter));
        _assertAdapterAttempts(address(aerodromeCLSwapAdapter));
        _assertAdapterAttempts(address(agentTransferAdapter));
        _assertAdapterAttempts(address(aaveV3LendingAdapter));
        _assertAdapterAttempts(address(aaveV4LendingAdapter));
        _assertAdapterAttempts(address(morphoBlueLendingAdapter));
        _assertAdapterBlocked(address(erc4626Adapter));
        _assertAdapterBlocked(address(aaveV3Adapter));
        _assertAdapterBlocked(address(compoundV2Adapter));
        _assertAdapterBlocked(address(compoundV3Adapter));
        _assertAdapterBlocked(address(merklAdapter));
        _assertAdapterBlocked(address(moonwellRewardAdapter));
        _assertAdapterBlocked(address(uniswapV3SwapAdapter));
        _assertAdapterBlocked(address(aerodromeV2SwapAdapter));
        _assertAdapterBlocked(address(aerodromeCLSwapAdapter));
        _assertAdapterBlocked(address(agentTransferAdapter));
        _assertAdapterBlocked(address(aaveV3LendingAdapter));
        _assertAdapterBlocked(address(aaveV4LendingAdapter));
        _assertAdapterBlocked(address(morphoBlueLendingAdapter));
    }

    function logWorkflowCounts() external view {
        console2.log("vault attempts", vaultWorkflowAttempts);
        console2.log("vault blocked", vaultWorkflowBlocks);
        console2.log("reward attempts", rewardWorkflowAttempts);
        console2.log("reward blocked", rewardWorkflowBlocks);
        console2.log("lending attempts", lendingWorkflowAttempts);
        console2.log("lending blocked", lendingWorkflowBlocks);
        console2.log("swap attempts", swapWorkflowAttempts);
        console2.log("swap blocked", swapWorkflowBlocks);
        console2.log("transfer attempts", transferWorkflowAttempts);
        console2.log("transfer blocked", transferWorkflowBlocks);
        console2.log("arbitrary call attempts", arbitraryCallAttempts);
        console2.log("arbitrary call blocked", arbitraryCallBlocks);
        console2.log("privileged attempts", privilegedCallAttempts);
        console2.log("privileged blocked", privilegedCallBlocks);
        console2.log("UserOp attempts", userOpAttempts);
        console2.log("UserOps without paymaster blocked", userOpWithoutPaymasterBlocks);
        console2.log("sponsored UserOps accepted", sponsoredUserOpSuccesses);
        console2.log("unregistered attempts", unregisteredTargetAttempts);
        console2.log("unregistered blocked", unregisteredTargetBlocks);
        console2.log("hostile token attempts", hostileTokenAttempts);
        console2.log("hostile token blocked", hostileTokenBlocks);
        console2.log("factory wallet attempts", factoryWalletAttempts);
        console2.log("factory wallet blocked", factoryWalletBlocks);
        console2.log("owner withdraw attempts", ownerWithdrawAttempts);
        console2.log("owner withdraw successes", ownerWithdrawSuccesses);
        console2.log("owner blocklist calls", ownerBlocklistCalls);
        console2.log("cross-owner transfer attempts", crossOwnerTransferAttempts);
        console2.log("cross-owner transfer blocked", crossOwnerTransferBlocks);
        console2.log("wallet ETH spend attempts", walletEthSpendAttempts);
        console2.log("wallet ETH spend blocked", walletEthSpendBlocks);
        console2.log("EntryPoint spend attempts", entryPointSpendAttempts);
        console2.log("EntryPoint spend blocked", entryPointSpendBlocks);
        console2.log("price/time moves", priceAndTimeMoves);
        console2.log("liquidation attempts", liquidationAttempts);
        console2.log("liquidation blocked", liquidationBlocks);
        console2.log("liquidation successes", liquidationSuccesses);
        console2.log("Morpho liquidation bonus (USDC)", liquidationBonusValue);
        console2.log("Morpho repaid value (USDC)", liquidationRepaidValue);
        console2.log("Morpho interest budget (USDC)", morphoInterestBudget);
        console2.log("Morpho borrow-fee growth (WETH)", morphoBorrowFeeGrowth);
        console2.log("ERC4626 adapter attempts", adapterAttempts[address(erc4626Adapter)]);
        console2.log("ERC4626 adapter blocked", adapterBlocks[address(erc4626Adapter)]);
        console2.log("Aave V3 vault attempts", adapterAttempts[address(aaveV3Adapter)]);
        console2.log("Aave V3 vault blocked", adapterBlocks[address(aaveV3Adapter)]);
        console2.log("Compound V2 attempts", adapterAttempts[address(compoundV2Adapter)]);
        console2.log("Compound V2 blocked", adapterBlocks[address(compoundV2Adapter)]);
        console2.log("Compound V3 attempts", adapterAttempts[address(compoundV3Adapter)]);
        console2.log("Compound V3 blocked", adapterBlocks[address(compoundV3Adapter)]);
        console2.log("Merkl attempts", adapterAttempts[address(merklAdapter)]);
        console2.log("Merkl blocked", adapterBlocks[address(merklAdapter)]);
        console2.log("Moonwell attempts", adapterAttempts[address(moonwellRewardAdapter)]);
        console2.log("Moonwell blocked", adapterBlocks[address(moonwellRewardAdapter)]);
        console2.log("Uniswap attempts", adapterAttempts[address(uniswapV3SwapAdapter)]);
        console2.log("Uniswap blocked", adapterBlocks[address(uniswapV3SwapAdapter)]);
        console2.log("Aerodrome V2 attempts", adapterAttempts[address(aerodromeV2SwapAdapter)]);
        console2.log("Aerodrome V2 blocked", adapterBlocks[address(aerodromeV2SwapAdapter)]);
        console2.log("Aerodrome CL attempts", adapterAttempts[address(aerodromeCLSwapAdapter)]);
        console2.log("Aerodrome CL blocked", adapterBlocks[address(aerodromeCLSwapAdapter)]);
        console2.log("agent transfer attempts", adapterAttempts[address(agentTransferAdapter)]);
        console2.log("agent transfer blocked", adapterBlocks[address(agentTransferAdapter)]);
        console2.log("Aave V3 lending attempts", adapterAttempts[address(aaveV3LendingAdapter)]);
        console2.log("Aave V3 lending blocked", adapterBlocks[address(aaveV3LendingAdapter)]);
        console2.log("Aave V4 lending attempts", adapterAttempts[address(aaveV4LendingAdapter)]);
        console2.log("Aave V4 lending blocked", adapterBlocks[address(aaveV4LendingAdapter)]);
        console2.log("Morpho attempts", adapterAttempts[address(morphoBlueLendingAdapter)]);
        console2.log("Morpho blocked", adapterBlocks[address(morphoBlueLendingAdapter)]);
    }

    function ownerExitsEveryWallet() external {
        for (uint256 i; i < _ownerAWallets.length; i++) {
            _ownerExit(_ownerAWallets[i], ownerA);
        }
        for (uint256 i; i < _ownerBWallets.length; i++) {
            _ownerExit(_ownerBWallets[i], ownerB);
        }
    }

    function _exerciseAaveV3Lending(AgentWallet wallet, uint96 amountSeed) private {
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        (bool success,) = _operatorExecute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, uint256(0))));
        if (!success) lendingWorkflowBlocks++;
        _operatorExecute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, _smallSupplyAmount(wallet, amountSeed))));
        uint256 borrowAmount = _smallBorrowAmount(amountSeed);
        _operatorExecute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowAmount)));
        _operatorExecute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, borrowAmount / 2)));
        _operatorExecute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, USDC_UNIT)));
        _refreshBorrowBudgets(wallet);
    }

    function _exerciseAaveV4Lending(AgentWallet wallet, uint96 amountSeed) private {
        address target = aaveV4LendingAdapter.marketTarget(aaveV4Market);
        (bool success,) = _operatorExecute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.borrow, (aaveV4Market, uint256(0))));
        if (!success) lendingWorkflowBlocks++;
        _operatorExecute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.supplyCollateral, (aaveV4Market, _smallSupplyAmount(wallet, amountSeed))));
        uint256 borrowAmount = _smallBorrowAmount(amountSeed);
        _operatorExecute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.borrow, (aaveV4Market, borrowAmount)));
        _operatorExecute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.repay, (aaveV4Market, borrowAmount / 2)));
        _operatorExecute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, USDC_UNIT)));
        _refreshBorrowBudgets(wallet);
    }

    function _exerciseMorphoLending(AgentWallet wallet, uint96 amountSeed) private {
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        uint256 collateralAmount = 2 * USDC_UNIT;
        if (usdc.balanceOf(address(wallet)) < collateralAmount) {
            uint256 shortfall = collateralAmount - usdc.balanceOf(address(wallet));
            if (usdc.balanceOf(address(_ownerAWallets[0])) < shortfall) {
                lendingWorkflowBlocks++;
                return;
            }
            _operatorTransfer(_ownerAWallets[0], wallet, address(usdc), shortfall);
        }
        (bool supplied,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.supplyCollateral, (morphoMarket, collateralAmount)));
        if (!supplied) {
            lendingWorkflowBlocks++;
            return;
        }
        IMorphoBlue.MarketParams memory params = _morphoParams();
        uint256 collateralValue = Math.mulDiv(collateralAmount, IMorphoOracle(params.oracle).price(), 1e36);
        uint256 borrowLimit = Math.mulDiv(collateralValue, params.lltv, 1e18);
        uint256 borrowAmount = Math.min(_smallBorrowAmount(amountSeed), borrowLimit / 2);
        (bool borrowed,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.borrow, (morphoMarket, borrowAmount)));
        if (!borrowed) {
            lendingWorkflowBlocks++;
            _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
            return;
        }
        (bool repaid,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.repay, (morphoMarket, type(uint256).max)));
        if (!repaid) lendingWorkflowBlocks++;
        (bool withdrawn,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        if (!withdrawn) lendingWorkflowBlocks++;
    }

    function _vaultRoundTrip(AgentWallet wallet, address adapter, address target, bytes memory zeroDepositData, uint96 amountSeed) private {
        (bool zeroSuccess,) = _operatorExecute(wallet, adapter, target, zeroDepositData);
        if (!zeroSuccess) {
            vaultWorkflowBlocks++;
        }
        uint256 available = usdc.balanceOf(address(wallet));
        uint256 amount = available == 0 ? 1 : bound(amountSeed, 1, available < 5 * USDC_UNIT ? available : 5 * USDC_UNIT);
        bytes memory depositData = _vaultDepositData(adapter, amount);
        _operatorExecute(wallet, adapter, target, depositData);
        uint256 shares = IERC20(target).balanceOf(address(wallet));
        bytes memory withdrawData = abi.encodeCall(erc4626Adapter.withdraw, (shares));
        (bool withdrew,) = _operatorExecute(wallet, adapter, target, withdrawData);
        if (!withdrew) vaultWorkflowBlocks++;
    }

    function _vaultDepositData(address adapter, uint256 amount) private view returns (bytes memory) {
        if (adapter == address(erc4626Adapter)) return abi.encodeCall(erc4626Adapter.deposit, (amount));
        if (adapter == address(aaveV3Adapter)) return abi.encodeCall(aaveV3Adapter.deposit, (amount));
        if (adapter == address(compoundV2Adapter)) return abi.encodeCall(compoundV2Adapter.deposit, (amount));
        return abi.encodeCall(compoundV3Adapter.deposit, (amount));
    }

    function _operatorVaultBatch(AgentWallet wallet, uint96 amountSeed) private {
        uint256 available = usdc.balanceOf(address(wallet));
        uint256 amount = available == 0 ? 1 : bound(amountSeed, 1, available < USDC_UNIT ? available : USDC_UNIT);
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory calls = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(aaveV3Adapter);
        targets[0] = address(erc4626Vault);
        targets[1] = address(aaveV3Vault);
        calls[0] = abi.encodeCall(erc4626Adapter.deposit, (amount));
        calls[1] = abi.encodeCall(aaveV3Adapter.deposit, (amount));
        uint256 feesBefore = _feeCollectorValue();
        vm.prank(operator);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapterBatch, (adapters, targets, calls)));
        adapterAttempts[address(erc4626Adapter)]++;
        adapterAttempts[address(aaveV3Adapter)]++;
        if (success) {
            feesPaidByOwner[wallet.owner()] += _feeCollectorValue() - feesBefore;
        } else {
            adapterBlocks[address(erc4626Adapter)]++;
            adapterBlocks[address(aaveV3Adapter)]++;
            vaultWorkflowBlocks++;
        }
    }

    function _claimMerkl(AgentWallet wallet, uint256 rewardIncrement) private {
        uint256 amount = _merklClaimed[address(wallet)] + rewardIncrement;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        (bool success,) = _operatorExecute(wallet, address(merklAdapter), address(merklDistributor), abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
        if (success) {
            _merklClaimed[address(wallet)] = amount;
        } else {
            rewardWorkflowBlocks++;
        }
    }

    function _claimMoonwell(AgentWallet wallet) private {
        address[] memory markets = new address[](1);
        markets[0] = address(compoundV2Vault);
        (bool success,) = _operatorExecute(wallet, address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (address(wallet), markets)));
        if (!success) rewardWorkflowBlocks++;
    }

    function _claimMoonwellWithThiefHolder(AgentWallet wallet) private {
        address[] memory markets = new address[](1);
        markets[0] = address(compoundV2Vault);
        (bool success,) = _operatorExecute(wallet, address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (thief, markets)));
        if (!success) rewardWorkflowBlocks++;
    }

    function _tryUnregisteredRewardClaim(AgentWallet wallet) private {
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        unregisteredTargetAttempts++;
        (bool success,) = _operatorExecute(wallet, address(merklAdapter), address(hostileVault), abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
        if (!success) {
            unregisteredTargetBlocks++;
            rewardWorkflowBlocks++;
        }
    }

    function _sellRewardOnAllDexes(AgentWallet wallet, address token, uint96 amountSeed) private {
        _sellRewardOnOneDex(wallet, token, 0, amountSeed);
        _sellRewardOnOneDex(wallet, token, 1, amountSeed);
        _sellRewardOnOneDex(wallet, token, 2, amountSeed);
    }

    function _sellRewardOnOneDex(AgentWallet wallet, address token, uint8 dex, uint96 amountSeed) private {
        address baseAsset = address(wallet.baseAsset());
        uint256 balance = IERC20(token).balanceOf(address(wallet));
        uint256 amount = balance == 0 ? 1 : bound(amountSeed, 1, balance);
        _setDexBuyAmount(dex, 1);
        (address adapter, address target, bytes memory callData) = _swapCall(dex, token, baseAsset, amount, 1);
        swapWorkflowAttempts++;
        (bool success,) = _operatorExecute(wallet, adapter, target, callData);
        if (success) {
            acceptedLossBudget[wallet.owner()] += _tokenValueCeil(token, amount);
        } else {
            swapWorkflowBlocks++;
        }
        (,, bytes memory zeroMinCall) = _swapCall(dex, token, baseAsset, amount, 0);
        swapWorkflowAttempts++;
        (success,) = _operatorExecute(wallet, adapter, target, zeroMinCall);
        if (success) acceptedLossBudget[wallet.owner()] += _tokenValueCeil(token, amount);
        else swapWorkflowBlocks++;
    }

    function _dumpAllReward(AgentWallet wallet, address token, uint8 dex) private {
        uint256 amount = IERC20(token).balanceOf(address(wallet));
        assertGt(amount, 0);
        address baseAsset = address(wallet.baseAsset());
        _setDexBuyAmount(dex, 1);
        (address adapter, address target, bytes memory callData) = _swapCall(dex, token, baseAsset, amount, 1);
        uint256 beforeValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
        (bool success,) = _operatorExecute(wallet, adapter, target, callData);
        assertTrue(success);
        uint256 afterValue = _ownerValue(ownerA) + feesPaidByOwner[ownerA];
        uint256 loss = beforeValue > afterValue ? beforeValue - afterValue : 0;
        uint256 rewardBound = _tokenValueCeil(token, amount);
        assertLe(loss, rewardBound);
        acceptedLossBudget[ownerA] += rewardBound;
    }

    function _swapCall(uint8 dex, address sellToken, address buyToken, uint256 amount, uint256 minimum) private view returns (address adapter, address target, bytes memory callData) {
        address[] memory path = new address[](2);
        path[0] = sellToken;
        path[1] = buyToken;
        if (dex == 0) {
            uint24[] memory fees = new uint24[](1);
            fees[0] = 3_000;
            AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
            adapter = address(uniswapV3SwapAdapter);
            target = address(uniswapV3Router);
            callData = abi.encodeCall(uniswapV3SwapAdapter.swap, (sellToken, buyToken, route, amount, minimum, block.timestamp));
        } else if (dex == 1) {
            bool[] memory stables = new bool[](1);
            AWKAerodromeV2SwapAdapter.SwapRoute memory route = AWKAerodromeV2SwapAdapter.SwapRoute({path: path, stables: stables});
            adapter = address(aerodromeV2SwapAdapter);
            target = address(aerodromeV2Router);
            callData = abi.encodeCall(aerodromeV2SwapAdapter.swap, (sellToken, buyToken, route, amount, minimum, block.timestamp));
        } else {
            int24[] memory tickSpacings = new int24[](1);
            tickSpacings[0] = 100;
            AWKAerodromeCLSwapAdapter.SwapRoute memory route = AWKAerodromeCLSwapAdapter.SwapRoute({path: path, tickSpacings: tickSpacings});
            adapter = address(aerodromeCLSwapAdapter);
            target = address(aerodromeCLRouter);
            callData = abi.encodeCall(aerodromeCLSwapAdapter.swap, (sellToken, buyToken, route, amount, minimum, block.timestamp));
        }
    }

    function _setDexBuyAmount(uint8 dex, uint256 amount) private {
        if (dex == 0) uniswapV3Router.setBuyAmount(amount);
        else if (dex == 1) aerodromeV2Router.setBuyAmount(amount);
        else aerodromeCLRouter.setBuyAmount(amount);
    }

    function _tryBorrowSwapAtOracleFloor(AgentWallet wallet) private returns (bool success) {
        return _tryBorrowSwapAtOracleFloor(wallet, USDC_UNIT);
    }

    function _tryBorrowSwapAtOracleFloor(AgentWallet wallet, uint256 amount) private returns (bool success) {
        uint256 balance = usdc.balanceOf(address(wallet));
        if (balance < amount) {
            uint256 available = usdc.balanceOf(address(_ownerAWallets[0]));
            if (available >= amount) _operatorTransfer(_ownerAWallets[0], wallet, address(usdc), amount);
        }
        uint256 availableAfter = usdc.balanceOf(address(wallet));
        if (availableAfter < amount) amount = availableAfter;
        if (amount == 0) amount = 1;
        uint256 quote = priceOracleQuote(address(usdc), address(weth), amount);
        uint256 minimum = Math.mulDiv(quote, 9_900, 10_000, Math.Rounding.Ceil);
        _setDexBuyAmount(0, minimum);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amount, minimum, block.timestamp));
        swapWorkflowAttempts++;
        uint256 feesBefore = _feeCollectorValue();
        vm.prank(operator);
        (success,) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapter, (address(uniswapV3SwapAdapter), address(uniswapV3Router), data)));
        adapterAttempts[address(uniswapV3SwapAdapter)]++;
        if (success) {
            feesPaidByOwner[wallet.owner()] += _feeCollectorValue() - feesBefore;
            acceptedLossBudget[wallet.owner()] += Math.mulDiv(amount, 100, 10_000, Math.Rounding.Ceil);
            _refreshBorrowBudgets(wallet);
        } else {
            adapterBlocks[address(uniswapV3SwapAdapter)]++;
            swapWorkflowBlocks++;
        }
    }

    function _tryBorrowSwapAboveDebtCap(AgentWallet wallet) private {
        uint256 amountIn = USDC_UNIT;
        assertGe(usdc.balanceOf(address(wallet)), amountIn);

        uint256 debt = borrowFeeModuleDebt(address(wallet));
        uint256 maxBalance = Math.mulDiv(debt, 10_000 + DEBT_BUFFER_BPS, 10_000);
        uint256 held = weth.balanceOf(address(wallet));
        assertLe(held, maxBalance);
        uint256 amountOut = maxBalance - held + 1;
        uniswapV3Router.setBuyAmount(amountOut);

        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, 0, block.timestamp));
        swapWorkflowAttempts++;
        (bool success,) = _operatorExecute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertFalse(success);
        swapWorkflowBlocks++;
    }

    function _runMorphoLiquidationLifecycle(MorphoLifecycleSetup memory setup) private {
        uint256 bonusBefore = liquidationBonusValue;
        uint256 repaidBefore = liquidationRepaidValue;
        for (uint256 i; i < setup.rounds; i++) {
            _runMorphoLiquidationRound(setup);
        }
        if (setup.requireSuccess) {
            uint256 bonus = liquidationBonusValue - bonusBefore;
            uint256 repaid = liquidationRepaidValue - repaidBefore;
            assertGt(repaid, 0);
            assertLe(bonus, Math.mulDiv(repaid, 440, 10_000, Math.Rounding.Ceil) + setup.rounds);
        }
    }

    function _runMorphoLiquidationRound(MorphoLifecycleSetup memory setup) private {
        if (!_supplyAndBorrowMorpho(setup)) return;
        MorphoAccrualSnapshot memory snapshot = _snapshotMorphoAccrual(setup.wallet);
        _assertNoImmediateMorphoAccrual(setup.wallet, snapshot);
        _warpAndRefreshPrices(setup.elapsed);
        _accrueMorphoAndTrackInterest();
        _assertMorphoInterestGrowth(setup.wallet, setup.elapsed, snapshot);
        _assertMorphoBorrowFeeGrowth(setup.wallet, setup.elapsed, snapshot);
        _liquidateMorphoPosition(setup.wallet, setup.requireSuccess);
    }

    function _supplyAndBorrowMorpho(MorphoLifecycleSetup memory setup) private returns (bool) {
        if (!_supplyMorphoCollateral(setup)) return false;
        return _borrowMorphoAtLimit(setup);
    }

    function _supplyMorphoCollateral(MorphoLifecycleSetup memory setup) private returns (bool) {
        AgentWallet wallet = setup.wallet;
        uint256 available = usdc.balanceOf(address(wallet));
        if (available < setup.collateralAmount) {
            uint256 shortfall = setup.collateralAmount - available;
            if (usdc.balanceOf(address(setup.source)) < shortfall) {
                _blockMorphoLifecycle(setup.requireSuccess);
                return false;
            }
            _operatorTransfer(setup.source, wallet, address(usdc), shortfall);
        }
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        (bool supplied,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.supplyCollateral, (morphoMarket, setup.collateralAmount)));
        if (!supplied) {
            _blockMorphoLifecycle(setup.requireSuccess);
            return false;
        }
        return true;
    }

    function _borrowMorphoAtLimit(MorphoLifecycleSetup memory setup) private returns (bool) {
        AgentWallet wallet = setup.wallet;
        IMorphoBlue.MarketParams memory params = _morphoParams();
        uint256 collateralValue = Math.mulDiv(setup.collateralAmount, IMorphoOracle(params.oracle).price(), 1e36);
        uint256 borrowLimit = Math.mulDiv(collateralValue, params.lltv, 1e18);
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        (bool borrowed,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.borrow, (morphoMarket, borrowLimit)));
        if (!borrowed) {
            _blockMorphoLifecycle(setup.requireSuccess);
            _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
            return false;
        }
        return true;
    }

    function _blockMorphoLifecycle(bool requireSuccess) private {
        liquidationAttempts++;
        liquidationBlocks++;
        if (requireSuccess) assertTrue(false);
    }

    function _snapshotMorphoAccrual(AgentWallet wallet) private view returns (MorphoAccrualSnapshot memory snapshot) {
        snapshot.debt = _morphoDebt(address(wallet));
        assertGt(snapshot.debt, 0);
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        address position = morphoBlueLendingAdapter.debtPosition(morphoMarket);
        snapshot.fee = module.pendingFee(address(wallet), position);
        snapshot.costs = _protocolCosts(wallet);
    }

    function _assertNoImmediateMorphoAccrual(AgentWallet wallet, MorphoAccrualSnapshot memory snapshot) private {
        morpho.accrueInterest(_morphoParams());
        assertEq(_morphoDebt(address(wallet)), snapshot.debt);
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        address position = morphoBlueLendingAdapter.debtPosition(morphoMarket);
        assertEq(module.pendingFee(address(wallet), position), snapshot.fee);
        assertEq(_protocolCosts(wallet), snapshot.costs);
    }

    function _assertMorphoInterestGrowth(AgentWallet wallet, uint256 elapsed, MorphoAccrualSnapshot memory snapshot) private view {
        uint256 debtAfterTime = _morphoDebt(address(wallet));
        uint256 interest = debtAfterTime - snapshot.debt;
        uint256 expectedInterest = Math.mulDiv(snapshot.debt, 500 * elapsed, 10_000 * 365 days);
        assertGt(interest, 0);
        assertLe(interest, expectedInterest + 10);
        assertGe(interest + 10, expectedInterest);
    }

    function _assertMorphoBorrowFeeGrowth(AgentWallet wallet, uint256 elapsed, MorphoAccrualSnapshot memory snapshot) private {
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        address position = morphoBlueLendingAdapter.debtPosition(morphoMarket);
        uint256 feeAfterTime = module.pendingFee(address(wallet), position);
        uint256 rateBps = module.walletPlan(address(wallet)).rateBps;
        uint256 expectedFee = Math.mulDiv(snapshot.debt, rateBps * elapsed, 10_000 * 365 days, Math.Rounding.Ceil);
        assertEq(feeAfterTime - snapshot.fee, expectedFee);
        assertGt(_protocolCosts(wallet), snapshot.costs);
        morphoBorrowFeeGrowth += feeAfterTime - snapshot.fee;
    }

    function _liquidateMorphoPosition(AgentWallet wallet, bool requireSuccess) private {
        liquidationAttempts++;
        vm.prank(thief);
        (bool liquidated, bytes memory result) = address(morpho).call(abi.encodeCall(morpho.liquidate, (_morphoParams(), address(wallet), 0, type(uint256).max, bytes(""))));
        if (!liquidated) {
            liquidationBlocks++;
            if (requireSuccess) assertTrue(false);
            return;
        }
        (uint256 repaidAssets, uint256 seizedCollateral) = abi.decode(result, (uint256, uint256));
        _recordSuccessfulLiquidation(wallet, repaidAssets, seizedCollateral);
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        (bool checkpointed,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.checkpoint, (morphoMarket)));
        if (!checkpointed && requireSuccess) assertTrue(false);
        (bool withdrawn,) = _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        if (!withdrawn && requireSuccess) assertTrue(false);
        if (requireSuccess) {
            assertEq(_morphoDebt(address(wallet)), 0);
            assertEq(_morphoCollateral(address(wallet)), 0);
        }
    }

    function _recordSuccessfulLiquidation(AgentWallet wallet, uint256 repaidAssets, uint256 seizedCollateral) private {
        uint256 repaidValue = _wethValueCeil(repaidAssets);
        uint256 bonus = seizedCollateral > repaidValue ? seizedCollateral - repaidValue : 0;
        uint256 incentive = morpho.liquidationIncentiveFactor(_morphoParams().lltv);
        uint256 maximumBonus = Math.mulDiv(repaidValue, incentive - 1e18, 1e18, Math.Rounding.Ceil) + 1;
        assertLe(bonus, maximumBonus);
        liquidationWethSpent += repaidAssets;
        liquidationCollateralReceived += seizedCollateral;
        liquidationBonusValue += bonus;
        liquidationRepaidValue += repaidValue;
        liquidationSuccesses++;
        acceptedLossBudget[wallet.owner()] += bonus;
    }

    function _morphoParams() private view returns (IMorphoBlue.MarketParams memory marketParams) {
        (, marketParams) = abi.decode(morphoMarket, (address, IMorphoBlue.MarketParams));
    }

    function _tryLiquidation(AgentWallet wallet) private {
        _accrueMorphoAndTrackInterest();
        vm.prank(thief);
        (bool success, bytes memory result) = address(morpho).call(abi.encodeCall(morpho.liquidate, (_morphoParams(), address(wallet), 0, type(uint256).max, bytes(""))));
        liquidationAttempts++;
        if (!success) {
            liquidationBlocks++;
            return;
        }
        (uint256 repaidAssets, uint256 seizedCollateral) = abi.decode(result, (uint256, uint256));
        _recordSuccessfulLiquidation(wallet, repaidAssets, seizedCollateral);
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        _operatorExecute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.checkpoint, (morphoMarket)));
    }

    function _warpAndRefreshPrices(uint256 elapsed) private {
        vm.warp(block.timestamp + elapsed);
        int256 marketPrice = wethPriceFeed.answer();
        uint256 now_ = block.timestamp;
        wethPriceFeed.setPrice(marketPrice, now_);
        usdcPriceFeed.setPrice(usdcPriceFeed.answer(), now_);
        rewardPriceFeed.setPrice(rewardPriceFeed.answer(), now_);
        wellPriceFeed.setPrice(wellPriceFeed.answer(), now_);
        aaveV3LendingPool.setAssetPrice(address(weth), uint256(marketPrice));
        aaveV4Spoke.setReservePrice(2, uint256(marketPrice));
        morphoOracle.setPrice(Math.mulDiv(5e44, 2_000e8, uint256(marketPrice)));
    }

    function _accrueMorphoAndTrackInterest() private {
        uint256[] memory ownerADebts = new uint256[](_ownerAWallets.length);
        uint256[] memory ownerBDebts = new uint256[](_ownerBWallets.length);
        for (uint256 i; i < _ownerAWallets.length; i++) {
            ownerADebts[i] = _morphoDebt(address(_ownerAWallets[i]));
        }
        for (uint256 i; i < _ownerBWallets.length; i++) {
            ownerBDebts[i] = _morphoDebt(address(_ownerBWallets[i]));
        }
        morpho.accrueInterest(_morphoParams());
        _recordMorphoInterest(_ownerAWallets, ownerADebts, ownerA);
        _recordMorphoInterest(_ownerBWallets, ownerBDebts, ownerB);
    }

    function _recordMorphoInterest(AgentWallet[] storage wallets, uint256[] memory debtsBefore, address walletOwner) private {
        for (uint256 i; i < wallets.length; i++) {
            AgentWallet wallet = wallets[i];
            uint256 debtAfter = _morphoDebt(address(wallet));
            if (debtAfter > debtsBefore[i]) {
                uint256 interestValue = _wethValueCeil(debtAfter - debtsBefore[i]);
                acceptedLossBudget[walletOwner] += interestValue;
                morphoInterestBudget += interestValue;
            }
            if (wallet.agentProfile() == BORROW_AGENT_PROFILE) _refreshBorrowBudgets(wallet);
        }
    }

    function _tryUnregisteredTargets(AgentWallet wallet) private {
        (bool success,) = _operatorExecute(wallet, address(erc4626Adapter), address(hostileVault), abi.encodeCall(erc4626Adapter.deposit, (USDC_UNIT)));
        unregisteredTargetAttempts++;
        vaultWorkflowAttempts++;
        if (!success) {
            unregisteredTargetBlocks++;
            vaultWorkflowBlocks++;
        }

        address[] memory adapters = new address[](13);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(aaveV3Adapter);
        adapters[2] = address(compoundV2Adapter);
        adapters[3] = address(compoundV3Adapter);
        adapters[4] = address(merklAdapter);
        adapters[5] = address(moonwellRewardAdapter);
        adapters[6] = address(uniswapV3SwapAdapter);
        adapters[7] = address(aerodromeV2SwapAdapter);
        adapters[8] = address(aerodromeCLSwapAdapter);
        adapters[9] = address(agentTransferAdapter);
        adapters[10] = address(aaveV3LendingAdapter);
        adapters[11] = address(aaveV4LendingAdapter);
        adapters[12] = address(morphoBlueLendingAdapter);
        for (uint256 i; i < adapters.length; i++) {
            unregisteredTargetAttempts++;
            (success,) = _operatorExecute(wallet, adapters[i], address(hostileRouter), bytes(""));
            if (!success) {
                unregisteredTargetBlocks++;
                if (adapters[i] == address(erc4626Adapter) || adapters[i] == address(aaveV3Adapter) || adapters[i] == address(compoundV2Adapter) || adapters[i] == address(compoundV3Adapter)) vaultWorkflowBlocks++;
                else if (adapters[i] == address(merklAdapter) || adapters[i] == address(moonwellRewardAdapter)) rewardWorkflowBlocks++;
                else if (adapters[i] == address(uniswapV3SwapAdapter) || adapters[i] == address(aerodromeV2SwapAdapter) || adapters[i] == address(aerodromeCLSwapAdapter)) swapWorkflowBlocks++;
                else if (adapters[i] == address(agentTransferAdapter)) transferWorkflowBlocks++;
                else lendingWorkflowBlocks++;
            }
            if (adapters[i] == address(erc4626Adapter) || adapters[i] == address(aaveV3Adapter) || adapters[i] == address(compoundV2Adapter) || adapters[i] == address(compoundV3Adapter)) vaultWorkflowAttempts++;
            else if (adapters[i] == address(merklAdapter) || adapters[i] == address(moonwellRewardAdapter)) rewardWorkflowAttempts++;
            else if (adapters[i] == address(uniswapV3SwapAdapter) || adapters[i] == address(aerodromeV2SwapAdapter) || adapters[i] == address(aerodromeCLSwapAdapter)) swapWorkflowAttempts++;
            else if (adapters[i] == address(agentTransferAdapter)) transferWorkflowAttempts++;
            else lendingWorkflowAttempts++;
        }

        unregisteredTargetAttempts++;
        (success,) = _operatorExecute(wallet, address(hostileRouter), address(uniswapV3Router), bytes(""));
        if (!success) unregisteredTargetBlocks++;
    }

    function _tryHostileToken(AgentWallet wallet) private {
        hostileTokenAttempts++;
        (bool success, bytes memory result) = address(hostileToken).call(abi.encodeCall(hostileToken.trySteal, (address(usdc), address(wallet), thief, 1)));
        bool stole;
        if (success && result.length >= 32) stole = abi.decode(result, (bool));
        if (!stole) hostileTokenBlocks++;
        (address adapter, address target, bytes memory data) = _swapCall(0, address(hostileToken), address(usdc), 1, 1);
        (success,) = _operatorExecute(wallet, adapter, target, data);
        if (!success) hostileTokenBlocks++;
    }

    function _tryDirectArbitraryCalls(AgentWallet wallet) private {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSignature("execute(address,uint256,bytes)", address(hostileRouter), 0, bytes(""));
        calls[1] = abi.encodeWithSignature("executeBatch(address[],bytes[])", new address[](0), new bytes[](0));
        calls[2] = abi.encodeCall(wallet.executeViaAdapter, (address(erc4626Adapter), address(hostileVault), abi.encodeCall(erc4626Adapter.deposit, (USDC_UNIT))));
        calls[3] = abi.encodeCall(wallet.executeViaAdapterBatch, (new address[](0), new address[](0), new bytes[](0)));
        for (uint256 i; i < calls.length; i++) {
            arbitraryCallAttempts++;
            vm.prank(operator);
            (bool success,) = address(wallet).call(calls[i]);
            if (!success) arbitraryCallBlocks++;
        }
    }

    function _tryPrivilegedWalletCalls(AgentWallet wallet) private {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(wallet.blockAdapter, (address(uniswapV3SwapAdapter)));
        calls[1] = abi.encodeCall(wallet.unblockAdapter, (address(uniswapV3SwapAdapter)));
        calls[2] = abi.encodeCall(wallet.blockTarget, (address(uniswapV3Router)));
        calls[3] = abi.encodeCall(wallet.unblockTarget, (address(uniswapV3Router)));
        calls[4] = abi.encodeCall(wallet.withdrawAssetToUser, (thief, address(usdc), 1));
        calls[5] = abi.encodeCall(wallet.withdrawAllAssetToUser, (thief, address(usdc)));
        calls[6] = abi.encodeCall(wallet.withdrawAllAssetsToUser, (thief, _exitAssets(wallet)));
        calls[7] = abi.encodeCall(wallet.upgradeToLatest, ());
        calls[8] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(factory.agentWalletImplementation()), bytes(""));
        for (uint256 i; i < calls.length; i++) {
            privilegedCallAttempts++;
            vm.prank(operator);
            (bool success,) = address(wallet).call(calls[i]);
            if (!success) privilegedCallBlocks++;
        }
    }

    function _tryUserOps(AgentWallet wallet, uint96 salt) private {
        bytes32 userOpHash = keccak256(abi.encode(address(wallet), salt, block.timestamp));
        bytes memory callData = abi.encodeCall(wallet.executeViaAdapter, (address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (USDC_UNIT))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_operatorKey, userOpHash.toEthSignedMessageHash());
        bytes memory signature = abi.encodePacked(r, s, v);
        UserOperation memory userOp = UserOperation({
            sender: address(wallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 21_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: signature
        });
        userOpAttempts++;
        vm.prank(ENTRY_POINT_V06);
        uint256 result = IWalletV06Validation(address(wallet)).validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1);
        userOpWithoutPaymasterBlocks++;

        userOp.paymasterAndData = abi.encodePacked(address(0xBEEF));
        vm.prank(ENTRY_POINT_V06);
        result = IWalletV06Validation(address(wallet)).validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 0);
        sponsoredUserOpSuccesses++;

        PackedUserOperation memory packedUserOp;
        packedUserOp.sender = address(wallet);
        packedUserOp.nonce = 0;
        packedUserOp.callData = callData;
        packedUserOp.accountGasLimits = bytes32((uint256(500_000) << 128) | 500_000);
        packedUserOp.preVerificationGas = 21_000;
        packedUserOp.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
        packedUserOp.paymasterAndData = "";
        packedUserOp.signature = signature;
        userOpAttempts++;
        vm.prank(ENTRY_POINT_V07);
        result = IWalletPackedValidation(address(wallet)).validateUserOp(packedUserOp, userOpHash, 0);
        assertEq(result, 1);
        userOpWithoutPaymasterBlocks++;
    }

    function _tryWalletEthSpend(AgentWallet wallet) private {
        walletEthSpendAttempts++;
        vm.prank(operator);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.withdrawAllEthToUser, (thief)));
        if (!success) walletEthSpendBlocks++;
    }

    function _tryEntryPointSpend(AgentWallet wallet) private {
        entryPointSpendAttempts++;
        bytes memory withdrawal = abi.encodeCall(IOperatorEntryPoint.withdrawTo, (payable(thief), 1));
        vm.prank(operator);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.execute, (ENTRY_POINT_V06, 0, withdrawal)));
        if (!success) entryPointSpendBlocks++;
        entryPointSpendAttempts++;
        (success,) = _operatorExecute(wallet, address(erc4626Adapter), ENTRY_POINT_V06, withdrawal);
        if (!success) entryPointSpendBlocks++;
    }

    function _tryCrossOwnerTransfers() private {
        AgentWallet source = _ownerAWallets[1];
        AgentWallet other = _ownerBWallets[1];
        vm.prank(ownerA);
        source.unblockAdapter(address(agentTransferAdapter));
        vm.prank(ownerA);
        source.unblockTarget(address(agentTransferAdapter));
        bytes32[] memory otherOwnerState = _snapshotOwnerState(ownerB);
        transferWorkflowAttempts++;
        crossOwnerTransferAttempts++;
        (bool success,) = _operatorExecute(source, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (address(weth), address(other), 1)));
        if (!success) {
            transferWorkflowBlocks++;
            crossOwnerTransferBlocks++;
        }
        _assertOwnerState(ownerB, otherOwnerState);

        AgentWallet thiefWallet = thiefBorrow;
        transferWorkflowAttempts++;
        (success,) = _operatorExecute(source, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (address(weth), address(thiefWallet), 1)));
        if (!success) transferWorkflowBlocks++;
    }

    function _tryUnregisteredFactoryCreate() private {
        FeePlanChoice[] memory plans = _feePlans(VAULT_AGENT_PROFILE);
        vm.prank(thief);
        (bool success,) = address(factory).call(abi.encodeCall(factory.createAgentWallet, (thief, 999_999, address(usdc), VAULT_AGENT_PROFILE, plans)));
        factoryWalletAttempts++;
        if (!success) factoryWalletBlocks++;
    }

    function _ownerWithdrawSingle(AgentWallet wallet, address walletOwner, uint96 amountSeed) private {
        uint256 balance = usdc.balanceOf(address(wallet));
        uint256 amount = balance == 0 ? 0 : bound(amountSeed, 1, balance);
        _ownerWithdraw(wallet, walletOwner, abi.encodeCall(wallet.withdrawAssetToUser, (walletOwner, address(usdc), amount)));
    }

    function _ownerWithdrawAll(AgentWallet wallet, address walletOwner, address token) private {
        _ownerWithdraw(wallet, walletOwner, abi.encodeCall(wallet.withdrawAllAssetToUser, (walletOwner, token)));
    }

    function _ownerWithdrawBatch(AgentWallet wallet, address walletOwner, uint96 amountSeed) private {
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);
        uint256 usdcBalance = usdc.balanceOf(address(wallet));
        uint256 wethBalance = weth.balanceOf(address(wallet));
        amounts[0] = usdcBalance == 0 ? 0 : bound(amountSeed, 1, usdcBalance);
        amounts[1] = wethBalance == 0 ? 0 : bound(amountSeed, 1, wethBalance);
        _ownerWithdraw(wallet, walletOwner, abi.encodeCall(wallet.withdrawAssetsToUser, (walletOwner, assets, amounts)));
    }

    function _ownerWithdrawAllBatch(AgentWallet wallet, address walletOwner) private {
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);
        _ownerWithdraw(wallet, walletOwner, abi.encodeCall(wallet.withdrawAllAssetsToUser, (walletOwner, assets)));
    }

    function _ownerWithdraw(AgentWallet wallet, address walletOwner, bytes memory callData) private {
        uint256 ownerUsdcBefore = usdc.balanceOf(walletOwner);
        uint256 ownerWethBefore = weth.balanceOf(walletOwner);
        uint256 feesBefore = _feeCollectorValue();
        ownerWithdrawAttempts++;
        vm.prank(walletOwner);
        (bool success,) = address(wallet).call(callData);
        if (success) {
            ownerWithdrawSuccesses++;
            uint256 receivedUsdc = usdc.balanceOf(walletOwner) - ownerUsdcBefore;
            uint256 receivedWeth = weth.balanceOf(walletOwner) - ownerWethBefore;
            withdrawnValue[walletOwner] += receivedUsdc + _wethValue(receivedWeth);
            feesPaidByOwner[walletOwner] += _feeCollectorValue() - feesBefore;
            if (wallet.agentProfile() == BORROW_AGENT_PROFILE) _refreshBorrowBudgets(wallet);
        }
    }

    function _ownerBlocklists(AgentWallet wallet, address walletOwner, bool blockIt) private {
        address adapter = address(uniswapV3SwapAdapter);
        address target = address(uniswapV3Router);
        vm.prank(walletOwner);
        if (blockIt) wallet.blockAdapter(adapter);
        else wallet.unblockAdapter(adapter);
        vm.prank(walletOwner);
        if (blockIt) wallet.blockTarget(target);
        else wallet.unblockTarget(target);
        ownerBlocklistCalls += 2;
    }

    function _moveSupportedAssetToNewWallet(address walletOwner, AgentWallet receiver, address baseAsset) private {
        uint256 amount = baseAsset == address(weth) ? 1e12 : 1;
        AgentWallet sender = walletOwner == ownerA ? _ownerAWallets[0] : _ownerBWallets[0];
        if (IERC20(baseAsset).balanceOf(address(sender)) < amount) {
            sender = walletOwner == ownerA ? _ownerAWallets[1] : _ownerBWallets[1];
        }
        if (IERC20(baseAsset).balanceOf(address(sender)) >= amount) _operatorTransfer(sender, receiver, baseAsset, amount);
    }

    function _operatorTransfer(AgentWallet sender, AgentWallet receiver, address token, uint256 amount) private returns (bool success) {
        transferWorkflowAttempts++;
        if (amount == 0) {
            transferWorkflowBlocks++;
            return false;
        }
        (success,) = _operatorExecute(sender, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (token, address(receiver), amount)));
        if (!success) transferWorkflowBlocks++;
    }

    function _ownerExit(AgentWallet wallet, address walletOwner) private {
        _clearOwnerBlocks(wallet, walletOwner);
        if (wallet.agentProfile() == VAULT_AGENT_PROFILE) {
            _ownerCloseVault(wallet, walletOwner, address(erc4626Adapter), address(erc4626Vault), erc4626Vault.balanceOf(address(wallet)));
            _ownerCloseVault(wallet, walletOwner, address(aaveV3Adapter), address(aaveV3Vault), aaveV3Vault.balanceOf(address(wallet)));
            _ownerCloseVault(wallet, walletOwner, address(compoundV2Adapter), address(compoundV2Vault), compoundV2Vault.balanceOf(address(wallet)));
            _ownerCloseVault(wallet, walletOwner, address(compoundV3Adapter), address(compoundV3Market), compoundV3Market.balanceOf(address(wallet)));
            assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
            assertEq(aaveV3Vault.balanceOf(address(wallet)), 0);
            assertEq(compoundV2Vault.balanceOf(address(wallet)), 0);
            assertEq(compoundV3Market.balanceOf(address(wallet)), 0);
        } else {
            _ownerCloseBorrow(wallet, walletOwner);
        }
        _ownerClaimAndSellRewards(wallet, walletOwner);
        address baseAsset = address(wallet.baseAsset());
        uint256 walletBaseBefore = IERC20(baseAsset).balanceOf(address(wallet));
        uint256 ownerBaseBefore = IERC20(baseAsset).balanceOf(walletOwner);
        uint256 collectorBaseBefore = IERC20(baseAsset).balanceOf(feeCollector);
        vm.prank(walletOwner);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.withdrawAllAssetToUser, (walletOwner, baseAsset)));
        assertTrue(success);
        uint256 paid = IERC20(baseAsset).balanceOf(feeCollector) - collectorBaseBefore;
        assertEq(IERC20(baseAsset).balanceOf(walletOwner) - ownerBaseBefore, walletBaseBefore - paid);
        if (address(weth) != baseAsset && wallet.feeTracker().isAccountedToken(address(wallet), address(weth))) {
            uint256 walletWethBefore = weth.balanceOf(address(wallet));
            uint256 ownerWethBefore = weth.balanceOf(walletOwner);
            vm.prank(walletOwner);
            (success,) = address(wallet).call(abi.encodeCall(wallet.withdrawAllAssetToUser, (walletOwner, address(weth))));
            assertTrue(success);
            assertEq(weth.balanceOf(walletOwner) - ownerWethBefore, walletWethBefore);
        }
        assertEq(IERC20(baseAsset).balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        if (address(weth) != baseAsset) assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(rewardToken.balanceOf(address(wallet)), 0);
        assertEq(wellToken.balanceOf(address(wallet)), 0);
        assertEq(IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(address(wallet)), expectedEntryPointDeposit[address(wallet)]);
        uint256 ownerEthBefore = walletOwner.balance;
        uint256 walletEthBefore = address(wallet).balance;
        vm.prank(walletOwner);
        wallet.withdrawAllEthToUser(walletOwner);
        assertEq(walletOwner.balance - ownerEthBefore, walletEthBefore);
        assertEq(address(wallet).balance, 0);
    }

    function _ownerCloseVault(AgentWallet wallet, address walletOwner, address adapter, address target, uint256 shares) private {
        if (shares == 0) return;
        bytes memory data;
        if (adapter == address(erc4626Adapter)) data = abi.encodeCall(erc4626Adapter.withdraw, (shares));
        else if (adapter == address(aaveV3Adapter)) data = abi.encodeCall(aaveV3Adapter.withdraw, (shares));
        else if (adapter == address(compoundV2Adapter)) data = abi.encodeCall(compoundV2Adapter.withdraw, (shares));
        else data = abi.encodeCall(compoundV3Adapter.withdraw, (shares));
        _ownerExecute(wallet, walletOwner, adapter, target, data);
    }

    function _ownerCloseBorrow(AgentWallet wallet, address walletOwner) private {
        uint256 debtV3 = aaveV3VariableDebtTokenBalance(address(wallet));
        if (debtV3 > 0) {
            weth.mint(walletOwner, debtV3);
            vm.prank(walletOwner);
            weth.approve(address(aaveV3LendingPool), debtV3);
            vm.prank(walletOwner);
            aaveV3LendingPool.repay(address(weth), type(uint256).max, 2, address(wallet));
            address targetV3 = aaveV3LendingAdapter.marketTarget(aaveV3Market);
            _ownerExecute(wallet, walletOwner, address(aaveV3LendingAdapter), targetV3, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        }
        uint256 debtV4 = aaveV4Spoke.getUserTotalDebt(2, address(wallet));
        if (debtV4 > 0) {
            _ownerFundWallet(walletOwner, wallet, debtV4);
            address targetV4 = aaveV4LendingAdapter.marketTarget(aaveV4Market);
            _ownerExecute(wallet, walletOwner, address(aaveV4LendingAdapter), targetV4, abi.encodeCall(aaveV4LendingAdapter.repay, (aaveV4Market, type(uint256).max)));
        }
        uint256 morphoDebt = _morphoDebt(address(wallet));
        if (morphoDebt > 0) {
            _ownerFundWallet(walletOwner, wallet, morphoDebt);
            address targetMorpho = morphoBlueLendingAdapter.marketTarget(morphoMarket);
            _ownerExecute(wallet, walletOwner, address(morphoBlueLendingAdapter), targetMorpho, abi.encodeCall(morphoBlueLendingAdapter.repay, (morphoMarket, type(uint256).max)));
        }
        address collateralTargetV3 = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        if (aaveV3CollateralBalance(address(wallet)) > 0) _ownerExecute(wallet, walletOwner, address(aaveV3LendingAdapter), collateralTargetV3, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        address collateralTargetV4 = aaveV4LendingAdapter.marketTarget(aaveV4Market);
        if (aaveV4Spoke.getUserSuppliedAssets(1, address(wallet)) > 0) {
            _ownerExecute(wallet, walletOwner, address(aaveV4LendingAdapter), collateralTargetV4, abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, type(uint256).max)));
        }
        address collateralTargetMorpho = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        if (_morphoCollateral(address(wallet)) > 0) {
            _ownerExecute(wallet, walletOwner, address(morphoBlueLendingAdapter), collateralTargetMorpho, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        }
        assertEq(aaveV3VariableDebtTokenBalance(address(wallet)), 0);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), 0);
        assertEq(_morphoDebt(address(wallet)), 0);
        assertEq(aaveV3CollateralBalance(address(wallet)), 0);
        assertEq(aaveV4Spoke.getUserSuppliedAssets(1, address(wallet)), 0);
        assertEq(_morphoCollateral(address(wallet)), 0);
    }

    function _ownerFundWallet(address walletOwner, AgentWallet wallet, uint256 amount) private {
        uint256 current = weth.balanceOf(address(wallet));
        if (current >= amount) return;
        uint256 needed = amount - current;
        weth.mint(walletOwner, needed);
        vm.prank(walletOwner);
        weth.transfer(address(wallet), needed);
    }

    function _ownerClaimAndSellRewards(AgentWallet wallet, address walletOwner) private {
        if (wallet.agentProfile() == VAULT_AGENT_PROFILE && wellToken.balanceOf(address(moonwellComptroller)) >= moonwellComptroller.rewardPerMarket()) {
            address[] memory markets = new address[](1);
            markets[0] = address(compoundV2Vault);
            _ownerExecute(wallet, walletOwner, address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (address(wallet), markets)));
        }
        if (rewardToken.balanceOf(address(merklDistributor)) >= 1e18) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(rewardToken);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = _merklClaimed[address(wallet)] + 1e18;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = new bytes32[](0);
            _ownerExecute(wallet, walletOwner, address(merklAdapter), address(merklDistributor), abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
        }
        _ownerSellReward(wallet, walletOwner, address(rewardToken));
        _ownerSellReward(wallet, walletOwner, address(wellToken));
    }

    function _ownerSellReward(AgentWallet wallet, address walletOwner, address token) private {
        uint256 amount = IERC20(token).balanceOf(address(wallet));
        if (amount == 0) return;
        address baseAsset = address(wallet.baseAsset());
        uniswapV3Router.setBuyAmount(1);
        _ownerExecute(wallet, walletOwner, address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeCall(uniswapV3SwapAdapter.swap, (token, baseAsset, _uniswapRoute(token, baseAsset), amount, 1, block.timestamp)));
    }

    function _ownerExecute(AgentWallet wallet, address walletOwner, address adapter, address target, bytes memory data) private {
        vm.prank(walletOwner);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapter, (adapter, target, data)));
        assertTrue(success);
    }

    function _clearOwnerBlocks(AgentWallet wallet, address walletOwner) private {
        address[] memory adapters = new address[](13);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(aaveV3Adapter);
        adapters[2] = address(compoundV2Adapter);
        adapters[3] = address(compoundV3Adapter);
        adapters[4] = address(merklAdapter);
        adapters[5] = address(moonwellRewardAdapter);
        adapters[6] = address(uniswapV3SwapAdapter);
        adapters[7] = address(aerodromeV2SwapAdapter);
        adapters[8] = address(aerodromeCLSwapAdapter);
        adapters[9] = address(agentTransferAdapter);
        adapters[10] = address(aaveV3LendingAdapter);
        adapters[11] = address(aaveV4LendingAdapter);
        adapters[12] = address(morphoBlueLendingAdapter);
        for (uint256 i; i < adapters.length; i++) {
            if (wallet.isAdapterBlocked(adapters[i])) {
                vm.prank(walletOwner);
                wallet.unblockAdapter(adapters[i]);
            }
        }
        address[] memory targets = new address[](13);
        targets[0] = address(erc4626Vault);
        targets[1] = address(aaveV3Vault);
        targets[2] = address(compoundV2Vault);
        targets[3] = address(compoundV3Market);
        targets[4] = address(merklDistributor);
        targets[5] = address(moonwellComptroller);
        targets[6] = address(uniswapV3Router);
        targets[7] = address(aerodromeV2Router);
        targets[8] = address(aerodromeCLRouter);
        targets[9] = address(agentTransferAdapter);
        targets[10] = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        targets[11] = aaveV4LendingAdapter.marketTarget(aaveV4Market);
        targets[12] = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        for (uint256 i; i < targets.length; i++) {
            if (wallet.isTargetBlocked(targets[i])) {
                vm.prank(walletOwner);
                wallet.unblockTarget(targets[i]);
            }
        }
        address aTokenTarget = aaveV3LendingAdapter.collateralReceiptToken(aaveV3Market);
        if (wallet.isTargetBlocked(aTokenTarget)) {
            vm.prank(walletOwner);
            wallet.unblockTarget(aTokenTarget);
        }
    }

    function _ownerValue(address walletOwner) private view returns (uint256) {
        uint256 assets = _ownerGrossValue(walletOwner);
        uint256 debt = _ownerDebt(walletOwner);
        return assets > debt ? assets - debt : 0;
    }

    function _ownerGrossValue(address walletOwner) private view returns (uint256 value) {
        AgentWallet[] storage wallets = walletOwner == ownerA ? _ownerAWallets : _ownerBWallets;
        for (uint256 i; i < wallets.length; i++) {
            value += _walletGrossValue(wallets[i]);
        }
    }

    function _ownerDebt(address walletOwner) private view returns (uint256 debt) {
        AgentWallet[] storage wallets = walletOwner == ownerA ? _ownerAWallets : _ownerBWallets;
        for (uint256 i; i < wallets.length; i++) {
            AgentWallet wallet = wallets[i];
            uint256 tokenDebt = borrowFeeModuleDebt(address(wallet)) + _morphoUnreportedDebt(address(wallet));
            debt += _wethValueCeil(tokenDebt) + _protocolCosts(wallet);
        }
    }

    function _walletGrossValue(AgentWallet wallet) private view returns (uint256 value) {
        address account = address(wallet);
        value = usdc.balanceOf(account);
        value += _wethValue(weth.balanceOf(account));
        value += _tokenValue(address(rewardToken), rewardToken.balanceOf(account));
        value += _tokenValue(address(wellToken), wellToken.balanceOf(account));
        value += erc4626Vault.convertToAssets(erc4626Vault.balanceOf(account));
        value += aaveV3Vault.balanceOf(account);
        value += compoundV2Vault.balanceOfUnderlying(account);
        value += compoundV3Market.balanceOf(account);
        value += aaveV3CollateralBalance(account);
        value += aaveV4Spoke.getUserSuppliedAssets(1, account);
        value += _morphoCollateral(account);
    }

    function borrowFeeModuleDebt(address account) private view returns (uint256) {
        return _borrowFeeModule().tokenDebt(account, address(weth));
    }

    function _borrowFeeModule() private view returns (YieldSeekerBorrowFeeModule) {
        return YieldSeekerBorrowFeeModule(address(_ownerAWallets[1].feeTracker().feeModules(BORROW_FEE)));
    }

    function _morphoCollateral(address account) private view returns (uint256 collateral) {
        (, IMorphoBlue.MarketParams memory params) = abi.decode(morphoMarket, (address, IMorphoBlue.MarketParams));
        (,, uint128 held) = morpho.position(keccak256(abi.encode(params)), account);
        collateral = held;
    }

    function _morphoDebt(address account) private view returns (uint256 debt) {
        (, IMorphoBlue.MarketParams memory params) = abi.decode(morphoMarket, (address, IMorphoBlue.MarketParams));
        bytes32 id = keccak256(abi.encode(params));
        (, uint128 borrowShares,) = morpho.position(id, account);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(id);
        if (borrowShares > 0) debt = Math.mulDiv(borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6, Math.Rounding.Ceil);
    }

    function _morphoUnreportedDebt(address account) private view returns (uint256) {
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        address position = morphoBlueLendingAdapter.debtPosition(morphoMarket);
        (uint128 reportedDebt,,) = module.debtPositions(account, position);
        uint256 actualDebt = _morphoDebt(account);
        return actualDebt > reportedDebt ? actualDebt - reportedDebt : 0;
    }

    function aaveV3CollateralBalance(address account) private view returns (uint256) {
        return aaveV3CollateralAToken.balanceOf(account);
    }

    function aaveV3VariableDebtTokenBalance(address account) private view returns (uint256) {
        return aaveV3VariableDebtToken.balanceOf(account);
    }

    function _wethValue(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, uint256(wethPriceFeed.answer()), uint256(usdcPriceFeed.answer()) * 1e12);
    }

    function _wethValueCeil(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, uint256(wethPriceFeed.answer()), uint256(usdcPriceFeed.answer()) * 1e12, Math.Rounding.Ceil);
    }

    function _tokenValue(address token, uint256 amount) private view returns (uint256) {
        if (token == address(usdc)) return amount;
        if (token == address(weth)) return _wethValue(amount);
        uint256 price = token == address(wellToken) ? uint256(wellPriceFeed.answer()) : uint256(rewardPriceFeed.answer());
        return Math.mulDiv(amount, price, uint256(usdcPriceFeed.answer()) * 1e12);
    }

    function _tokenValueCeil(address token, uint256 amount) private view returns (uint256) {
        if (token == address(usdc)) return amount;
        if (token == address(weth)) return _wethValueCeil(amount);
        uint256 price = token == address(wellToken) ? uint256(wellPriceFeed.answer()) : uint256(rewardPriceFeed.answer());
        return Math.mulDiv(amount, price, uint256(usdcPriceFeed.answer()) * 1e12, Math.Rounding.Ceil);
    }

    function priceOracleQuote(address sellToken, address buyToken, uint256 amount) private view returns (uint256) {
        return priceOracle.quote(sellToken, buyToken, amount);
    }

    function _smallSupplyAmount(AgentWallet wallet, uint96 amountSeed) private view returns (uint256) {
        uint256 available = usdc.balanceOf(address(wallet));
        if (available == 0) return 1;
        return bound(amountSeed, 1, available < 5 * USDC_UNIT ? available : 5 * USDC_UNIT);
    }

    function _smallBorrowAmount(uint96 amountSeed) private view returns (uint256) {
        return bound(amountSeed, 1e12, 1e15);
    }

    function _ownerWallet(uint8 choice) private view returns (AgentWallet) {
        if (choice % 2 == 0) return _ownerAWallets[choice % _ownerAWallets.length];
        return _ownerBWallets[choice % _ownerBWallets.length];
    }

    function _feeCollectorValue() private view returns (uint256) {
        return usdc.balanceOf(feeCollector) + _wethValue(weth.balanceOf(feeCollector)) + _tokenValue(address(rewardToken), rewardToken.balanceOf(feeCollector)) + _tokenValue(address(wellToken), wellToken.balanceOf(feeCollector));
    }

    function _refreshBorrowBudgets(AgentWallet wallet) private {
        address account = address(wallet);
        uint256 currentCosts = _protocolCosts(wallet);
        uint256 previousCosts = _trackedProtocolCosts[account];
        if (currentCosts > previousCosts) acceptedLossBudget[wallet.owner()] += currentCosts - previousCosts;
        else if (previousCosts > currentCosts) acceptedLossBudget[wallet.owner()] -= previousCosts - currentCosts;
        _trackedProtocolCosts[account] = currentCosts;
        _updateDebtBufferBudget(wallet);
    }

    function _protocolCosts(AgentWallet wallet) private view returns (uint256 costs) {
        YieldSeekerBorrowFeeModule module = _borrowFeeModule();
        address account = address(wallet);
        costs = _baseAssetValue(wallet, module.feesOwed(account));
        costs += _pendingFeeValue(wallet, module, aaveV3LendingAdapter.debtPosition(aaveV3Market));
        costs += _pendingFeeValue(wallet, module, aaveV4LendingAdapter.debtPosition(aaveV4Market));
        costs += _pendingFeeValue(wallet, module, morphoBlueLendingAdapter.debtPosition(morphoMarket));
    }

    function _pendingFeeValue(AgentWallet wallet, YieldSeekerBorrowFeeModule module, address position) private view returns (uint256) {
        uint256 pendingDebtFee = module.pendingFee(address(wallet), position);
        if (pendingDebtFee == 0) return 0;
        (,, uint192 lastPrice) = module.debtPositions(address(wallet), position);
        uint256 feeInBaseAsset = Math.mulDiv(pendingDebtFee, lastPrice, 1e36, Math.Rounding.Ceil);
        return _baseAssetValue(wallet, feeInBaseAsset);
    }

    function _baseAssetValue(AgentWallet wallet, uint256 amount) private view returns (uint256) {
        return address(wallet.baseAsset()) == address(weth) ? _wethValueCeil(amount) : amount;
    }

    function _updateDebtBufferBudget(AgentWallet wallet) private {
        address account = address(wallet);
        uint256 current = _wethValueCeil(Math.mulDiv(borrowFeeModuleDebt(account), DEBT_BUFFER_BPS, 10_000, Math.Rounding.Ceil));
        uint256 previous = _debtBufferBudget[account];
        if (current > previous) acceptedLossBudget[wallet.owner()] += current - previous;
        _debtBufferBudget[account] = current;
    }

    function _snapshotOwnerState(address walletOwner) private view returns (bytes32[] memory state) {
        AgentWallet[] storage wallets = walletOwner == ownerA ? _ownerAWallets : _ownerBWallets;
        state = new bytes32[](wallets.length);
        for (uint256 i; i < wallets.length; i++) {
            state[i] = _walletState(address(wallets[i]));
        }
    }

    function _assertOwnerState(address walletOwner, bytes32[] memory expectedState) private view {
        AgentWallet[] storage wallets = walletOwner == ownerA ? _ownerAWallets : _ownerBWallets;
        assertEq(wallets.length, expectedState.length);
        for (uint256 i; i < wallets.length; i++) {
            assertEq(_walletState(address(wallets[i])), expectedState[i]);
        }
    }

    function _walletState(address account) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                usdc.balanceOf(account),
                weth.balanceOf(account),
                rewardToken.balanceOf(account),
                wellToken.balanceOf(account),
                erc4626Vault.balanceOf(account),
                aaveV3Vault.balanceOf(account),
                compoundV2Vault.balanceOf(account),
                compoundV3Market.balanceOf(account),
                aaveV3CollateralBalance(account),
                aaveV3VariableDebtTokenBalance(account),
                aaveV4Spoke.getUserSuppliedAssets(1, account),
                aaveV4Spoke.getUserTotalDebt(2, account),
                _morphoCollateral(account),
                _morphoDebt(account)
            )
        );
    }

    function _operatorExecute(AgentWallet wallet, address adapter, address target, bytes memory data) private returns (bool success, bytes memory result) {
        uint256 feesBefore = _feeCollectorValue();
        vm.prank(operator);
        (success, result) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapter, (adapter, target, data)));
        adapterAttempts[adapter]++;
        if (success) {
            feesPaidByOwner[wallet.owner()] += _feeCollectorValue() - feesBefore;
            if (wallet.agentProfile() == BORROW_AGENT_PROFILE) _refreshBorrowBudgets(wallet);
        } else {
            adapterBlocks[adapter]++;
        }
    }

    function _uniswapRoute(address sellToken, address buyToken) private pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        address[] memory path = new address[](2);
        path[0] = sellToken;
        path[1] = buyToken;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3_000;
        route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
    }

    function _exitAssets(AgentWallet wallet) private view returns (address[] memory assets) {
        if (wallet.agentProfile() == BORROW_AGENT_PROFILE) {
            assets = new address[](2);
            assets[0] = address(usdc);
            assets[1] = address(weth);
        } else {
            assets = new address[](1);
            assets[0] = address(wallet.baseAsset());
        }
    }

    function _feePlans(bytes32 profile) private pure returns (FeePlanChoice[] memory plans) {
        if (profile == BORROW_AGENT_PROFILE) {
            plans = new FeePlanChoice[](2);
            plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
            plans[1] = FeePlanChoice({feeType: BORROW_FEE, planId: 0});
        } else {
            plans = new FeePlanChoice[](1);
            plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
        }
    }

    function _assertOwnerConservation(address walletOwner) private view {
        uint256 assets = _ownerGrossValue(walletOwner) + withdrawnValue[walletOwner] + feesPaidByOwner[walletOwner];
        uint256 liabilities = initialDeposits[walletOwner] + _ownerDebt(walletOwner);
        assertGe(assets + acceptedLossBudget[walletOwner], liabilities);
    }

    function _assertWalletEthAndEntryPointDeposits(address walletOwner) private view {
        AgentWallet[] storage wallets = walletOwner == ownerA ? _ownerAWallets : _ownerBWallets;
        for (uint256 i; i < wallets.length; i++) {
            address account = address(wallets[i]);
            assertEq(account.balance, expectedWalletEth[account]);
            assertEq(IOperatorEntryPoint(ENTRY_POINT_V06).balanceOf(account), expectedEntryPointDeposit[account]);
        }
    }

    function _assertNoOwnerAssets(address account) private view {
        assertEq(usdc.balanceOf(account), 0);
        assertEq(weth.balanceOf(account), 0);
        assertEq(rewardToken.balanceOf(account), 0);
        assertEq(wellToken.balanceOf(account), 0);
        _assertNoPositions(account);
    }

    function _assertNoPositions(address account) private view {
        assertEq(erc4626Vault.balanceOf(account), 0);
        assertEq(aaveV3Vault.balanceOf(account), 0);
        assertEq(compoundV2Vault.balanceOf(account), 0);
        assertEq(compoundV3Market.balanceOf(account), 0);
        assertEq(aaveV3CollateralBalance(account), 0);
        assertEq(aaveV3VariableDebtTokenBalance(account), 0);
        assertEq(aaveV4Spoke.getUserSuppliedAssets(1, account), 0);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, account), 0);
        assertEq(_morphoCollateral(account), 0);
        assertEq(_morphoDebt(account), 0);
    }

    function _assertAdapterAttempts(address adapter) private view {
        assertGt(adapterAttempts[adapter], 0);
    }

    function _assertAdapterBlocked(address adapter) private view {
        assertGt(adapterBlocks[adapter], 0);
    }
}

contract CompromisedOperatorInvariantTest is IntegrationBase {
    address private constant ENTRY_POINT_V06 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address private constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint256 private constant USDC_UNIT = 1e6;
    uint256 private constant WETH_UNIT = 1e18;
    uint256 private constant ETH_WALLET_BALANCE = 0.02 ether;
    uint256 private constant ENTRY_POINT_DEPOSIT = 0.05 ether;
    address private ownerB;
    address private thief;
    uint256 private operatorKey;
    AgentWallet private ownerAVault;
    AgentWallet private ownerABorrow;
    AgentWallet private ownerAWethSink;
    AgentWallet private ownerAMorpho;
    AgentWallet private ownerBVault;
    AgentWallet private ownerBBorrow;
    AgentWallet private thiefVault;
    AgentWallet private thiefBorrow;
    OperatorMorphoBlueMarket private operatorMorpho;
    bytes private operatorMorphoMarket;
    CompromisedOperatorHandler private handler;
    OperatorHostileToken private hostileToken;
    OperatorHostileRouter private hostileRouter;
    OperatorHostileVault private hostileVault;
    OperatorThiefReceiver private thiefReceiver;

    function setUp() public override {
        super.setUp();
        (, IMorphoBlue.MarketParams memory morphoParams) = abi.decode(morphoMarket, (address, IMorphoBlue.MarketParams));
        morphoParams.lltv = 0.86e18;
        operatorMorpho = new OperatorMorphoBlueMarket();
        operatorMorphoMarket = abi.encode(address(operatorMorpho), morphoParams);
        weth.mint(address(operatorMorpho), 1_000 * WETH_UNIT);
        _registerTarget(borrowRegistry, morphoBlueLendingAdapter.marketTarget(operatorMorphoMarket), address(morphoBlueLendingAdapter));
        ownerB = makeAddr("other compromised-operator owner");
        thief = makeAddr("separate thief EOA");
        (address operatorAddress, uint256 operatorKey_) = makeAddrAndKey("operator");
        assertEq(operatorAddress, operator);
        operatorKey = operatorKey_;
        ownerAVault = _createVaultWallet(owner, 1);
        ownerABorrow = _createBorrowWallet(owner, 2);
        ownerAWethSink = _createWalletWithBase(owner, 3, address(weth), VAULT_AGENT_PROFILE);
        ownerAMorpho = _createBorrowWallet(owner, 4);
        ownerBVault = _createVaultWallet(ownerB, 1);
        ownerBBorrow = _createBorrowWallet(ownerB, 2);
        thiefVault = _createVaultWallet(thief, 1);
        thiefBorrow = _createBorrowWallet(thief, 2);
        _fundWallet(ownerAMorpho, address(usdc), 10_000 * USDC_UNIT);
        weth.mint(thief, 50 * WETH_UNIT);
        vm.prank(thief);
        weth.approve(address(operatorMorpho), type(uint256).max);

        _fundWallet(ownerAVault, address(usdc), 5_000 * USDC_UNIT);
        _fundWallet(ownerABorrow, address(usdc), 5_000 * USDC_UNIT);
        _fundWallet(ownerBVault, address(usdc), 5_000 * USDC_UNIT);
        _fundWallet(ownerBBorrow, address(usdc), 5_000 * USDC_UNIT);
        _execute(ownerAVault, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (1_000 * USDC_UNIT)));
        _execute(ownerBVault, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (1_000 * USDC_UNIT)));
        _execute(ownerABorrow, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, 4_000 * USDC_UNIT)));
        _execute(ownerBBorrow, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, 4_000 * USDC_UNIT)));
        _execute(ownerABorrow, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, WETH_UNIT)));
        _execute(ownerBBorrow, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, WETH_UNIT)));

        hostileToken = new OperatorHostileToken();
        hostileRouter = new OperatorHostileRouter(thief);
        hostileVault = new OperatorHostileVault(IERC20(address(usdc)), thief);
        thiefReceiver = new OperatorThiefReceiver();
        _installEntryPointsAndSeedEth();
        handler = new CompromisedOperatorHandler(
            CompromisedOperatorSetup({
                ownerA: owner,
                ownerB: ownerB,
                operator: operator,
                operatorKey: operatorKey,
                thief: thief,
                feeCollector: feeCollector,
                ownerAVault: ownerAVault,
                ownerABorrow: ownerABorrow,
                ownerAWethSink: ownerAWethSink,
                ownerBVault: ownerBVault,
                ownerAMorpho: ownerAMorpho,
                ownerBBorrow: ownerBBorrow,
                thiefVault: thiefVault,
                thiefBorrow: thiefBorrow,
                factory: factory,
                usdc: usdc,
                weth: weth,
                rewardToken: rewardToken,
                wellToken: wellToken,
                erc4626Vault: erc4626Vault,
                aaveV3Vault: aaveV3Vault,
                compoundV2Vault: compoundV2Vault,
                compoundV3Market: compoundV3Market,
                aaveV3CollateralAToken: aaveV3CollateralAToken,
                aaveV3VariableDebtToken: aaveV3VariableDebtToken,
                aaveV3Adapter: aaveV3Adapter,
                compoundV2Adapter: compoundV2Adapter,
                compoundV3Adapter: compoundV3Adapter,
                erc4626Adapter: erc4626Adapter,
                merklAdapter: merklAdapter,
                moonwellRewardAdapter: moonwellRewardAdapter,
                uniswapV3SwapAdapter: uniswapV3SwapAdapter,
                aerodromeV2SwapAdapter: aerodromeV2SwapAdapter,
                aerodromeCLSwapAdapter: aerodromeCLSwapAdapter,
                agentTransferAdapter: agentTransferAdapter,
                aaveV3LendingAdapter: aaveV3LendingAdapter,
                aaveV4LendingAdapter: aaveV4LendingAdapter,
                morphoBlueLendingAdapter: morphoBlueLendingAdapter,
                aaveV3LendingPool: aaveV3LendingPool,
                aaveV4Spoke: aaveV4Spoke,
                morpho: operatorMorpho,
                morphoOracle: morphoOracle,
                merklDistributor: merklDistributor,
                moonwellComptroller: moonwellComptroller,
                uniswapV3Router: uniswapV3Router,
                aerodromeV2Router: aerodromeV2Router,
                aerodromeCLRouter: aerodromeCLRouter,
                usdcPriceFeed: usdcPriceFeed,
                wethPriceFeed: wethPriceFeed,
                rewardPriceFeed: rewardPriceFeed,
                wellPriceFeed: wellPriceFeed,
                priceOracle: priceOracle,
                aaveV3Market: aaveV3Market,
                aaveV4Market: aaveV4Market,
                morphoMarket: operatorMorphoMarket,
                hostileToken: hostileToken,
                hostileRouter: hostileRouter,
                hostileVault: hostileVault,
                thiefReceiver: thiefReceiver
            })
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.operatorRunsEveryVaultAdapter.selector;
        selectors[1] = handler.operatorClaimsAndDumpsRewards.selector;
        selectors[2] = handler.operatorRunsEveryBorrowAdapter.selector;
        selectors[3] = handler.operatorBlocksAndAttemptsEveryForbiddenPath.selector;
        selectors[4] = handler.honestOwnersWithdrawAndBlock.selector;
        selectors[5] = handler.operatorCreatesOwnerAndThiefWallets.selector;
        selectors[6] = handler.operatorMovesTimeAndPrices.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_compromisedOperatorCannotTakeOwnerValueAndOwnersCanExit() public {
        handler.assertOwnerConservation();
        handler.assertNoThiefAssetsOrPositions();
        handler.assertWalletEthAndEntryPointDeposits();
        uint256 snapshot = vm.snapshotState();
        handler.ownerExitsEveryWallet();
        assertTrue(vm.revertToState(snapshot));
        handler.assertWalletEthAndEntryPointDeposits();
    }

    function testFuzz_compromisedOperatorWorstCaseStaysWithinReadmeBounds(uint8 routeSeed) public {
        uint256 beforeValue = handler.ownerValue(owner);
        uint256 beforeWithdrawn = handler.withdrawnValue(owner);
        uint256 beforeFees = handler.feesPaidByOwner(owner);
        uint256 beforeBudget = handler.acceptedLossBudget(owner);
        uint256 beforeBonus = handler.liquidationBonusValue();
        uint256 beforeRepaid = handler.liquidationRepaidValue();
        uint256 beforeLiquidations = handler.liquidationSuccesses();
        uint256 beforeInterest = handler.morphoInterestBudget();
        uint256 beforeBorrowFeeGrowth = handler.morphoBorrowFeeGrowth();
        handler.runWorstCase(routeSeed);
        uint256 valueAfter = handler.ownerValue(owner) + handler.withdrawnValue(owner) - beforeWithdrawn + handler.feesPaidByOwner(owner) - beforeFees;
        uint256 budgetAfter = handler.acceptedLossBudget(owner);
        assertGe(valueAfter + budgetAfter, beforeValue + beforeBudget);
        uint256 bonus = handler.liquidationBonusValue() - beforeBonus;
        uint256 repaid = handler.liquidationRepaidValue() - beforeRepaid;
        assertEq(handler.liquidationSuccesses() - beforeLiquidations, 3);
        assertLe(bonus, Math.mulDiv(repaid, 440, 10_000, Math.Rounding.Ceil) + 3);
        assertGt(handler.morphoInterestBudget() - beforeInterest, 0);
        assertGt(handler.morphoBorrowFeeGrowth() - beforeBorrowFeeGrowth, 0);
    }

    function afterInvariant() public view {
        handler.assertAllWorkflowCounts();
        handler.logWorkflowCounts();
    }

    function _createWalletWithBase(address walletOwner, uint256 index, address baseAsset, bytes32 profile) private returns (AgentWallet wallet) {
        FeePlanChoice[] memory plans;
        if (profile == VAULT_AGENT_PROFILE) {
            plans = new FeePlanChoice[](1);
            plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
        } else {
            plans = new FeePlanChoice[](2);
            plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
            plans[1] = FeePlanChoice({feeType: BORROW_FEE, planId: 0});
        }
        vm.prank(operator);
        wallet = AgentWallet(payable(address(factory.createAgentWallet(walletOwner, index, baseAsset, profile, plans))));
    }

    function _installEntryPointsAndSeedEth() private {
        OperatorMockEntryPoint implementation = new OperatorMockEntryPoint();
        vm.etch(ENTRY_POINT_V06, address(implementation).code);
        vm.etch(ENTRY_POINT_V07, address(implementation).code);
        vm.deal(address(this), 1 ether);
        AgentWallet[6] memory wallets = [ownerAVault, ownerABorrow, ownerAWethSink, ownerAMorpho, ownerBVault, ownerBBorrow];
        for (uint256 i; i < wallets.length; i++) {
            vm.deal(address(wallets[i]), ETH_WALLET_BALANCE);
            IOperatorEntryPoint(ENTRY_POINT_V06).depositTo{value: ENTRY_POINT_DEPOSIT}(address(wallets[i]));
        }
    }
}
