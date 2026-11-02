// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {FeePlanChoice, InsufficientGasForModules, InvalidFeeModule, InvalidPlan, PaymentExceedsAvailable, UnknownFeeType, UnknownPlan, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {MockSwapAdapterPriceOracle} from "../mocks/MockSwapAdapterPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerProbeModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;
    address internal immutable _wallet;
    address internal immutable _trackedToken;
    uint256 internal immutable _owedAmount;

    constructor(address feeTracker_, bytes32 feeType_, address wallet_, address trackedToken_, uint256 owedAmount_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
        _wallet = wallet_;
        _trackedToken = trackedToken_;
        _owedAmount = owedAmount_;
    }

    function isValidPlan(bytes calldata plan) external pure override returns (bool) {
        return plan.length == 32 && abi.decode(plan, (uint256)) <= 10_000;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address wallet, address token) external view override returns (bool) {
        return wallet == _wallet && token == _trackedToken;
    }

    function feesOwedInBaseAsset(address wallet) external view override returns (uint256) {
        return wallet == _wallet ? _owedAmount : 0;
    }
}

contract FeeTrackerHostileModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;
    bool internal immutable _burnsGas;

    constructor(address feeTracker_, bytes32 feeType_, bool burnsGas_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
        _burnsGas = burnsGas_;
    }

    function isValidPlan(bytes calldata plan) external pure override returns (bool) {
        return plan.length == 32 && abi.decode(plan, (uint256)) <= 10_000;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external view override returns (bool) {
        _fail();
    }

    function feesOwedInBaseAsset(address) external view override returns (uint256) {
        _fail();
    }

    function _fail() internal view {
        if (_burnsGas) {
            while (true) {}
        }
        revert();
    }
}

contract FeeTrackerOverpayingModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address feeTracker_, bytes32 feeType_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
    }

    function isValidPlan(bytes calldata plan) external pure override returns (bool) {
        return plan.length == 32 && abi.decode(plan, (uint256)) <= 10_000;
    }

    function onAction(address, bytes32, bytes calldata, uint256 maxPayment) external pure override returns (uint256) {
        return maxPayment + 1;
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        return 0;
    }
}

contract FeeTrackerTest is Test {
    bytes32 internal constant PROBE_FEE = keccak256("probe");
    bytes32 internal constant REVERTING_FEE = keccak256("reverting");
    bytes32 internal constant GAS_BURNING_FEE = keccak256("gas-burning");

    address internal constant PROBE_TOKEN = address(0xBEEF);
    address internal constant UNTRACKED_TOKEN = address(0xCAFE);

    address internal admin = makeAddr("admin");
    address internal collector = makeAddr("collector");
    address internal ownerA = makeAddr("ownerA");

    MockERC20 internal baseAsset;
    MockERC20 internal debtToken;
    MockFeeWallet internal wallet;
    MockSwapAdapterPriceOracle internal oracle;
    YieldSeekerFeeTracker internal tracker;
    YieldSeekerYieldFeeModule internal vaultModule;
    YieldSeekerBorrowFeeModule internal borrowModule;
    uint256 internal initialYieldPlanId;
    uint256 internal initialBorrowPlanId;

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        debtToken = new MockERC20("Debt", "DEBT");
        wallet = new MockFeeWallet(ownerA, IERC20(address(baseAsset)));
        tracker = new YieldSeekerFeeTracker(admin, collector);
        oracle = new MockSwapAdapterPriceOracle();
        vaultModule = new YieldSeekerYieldFeeModule(tracker, 2_000);
        borrowModule = new YieldSeekerBorrowFeeModule(tracker, oracle, 500);
        bytes memory initialBorrowPlan = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 300}));
        bytes memory initialYieldPlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 1_000}));

        vm.startPrank(admin);
        tracker.setFeeModule(BORROW_FEE, borrowModule);
        tracker.setFeeModule(YIELD_FEE, vaultModule);
        initialBorrowPlanId = tracker.createPlan(BORROW_FEE, initialBorrowPlan);
        initialYieldPlanId = tracker.createPlan(YIELD_FEE, initialYieldPlan);
        tracker.setWalletFactory(address(this));
        vm.stopPrank();
    }

    function testPlansArePerFeeTypeNumberedFromZeroAndCappedAtModuleMaximum() public {
        assertEq(initialYieldPlanId, 0);
        assertEq(initialBorrowPlanId, 0);
        assertEq(tracker.planCount(YIELD_FEE), 1);
        assertEq(tracker.planCount(BORROW_FEE), 1);
        YieldSeekerYieldFeeModule.Plan memory storedYieldPlan = abi.decode(tracker.plan(YIELD_FEE, 0), (YieldSeekerYieldFeeModule.Plan));
        YieldSeekerBorrowFeeModule.Plan memory storedBorrowPlan = abi.decode(tracker.plan(BORROW_FEE, 0), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(storedYieldPlan.rateBps, 1_000);
        assertEq(storedBorrowPlan.rateBps, 300);

        uint256 yieldMaximum = vaultModule.MAX_FEE_RATE_BPS();
        uint256 borrowMaximum = borrowModule.MAX_FEE_RATE_BPS();
        uint256 tooHighYield = yieldMaximum + 1;
        uint256 tooHighBorrow = borrowMaximum + 1;
        bytes memory maximumYieldPlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: yieldMaximum}));
        bytes memory maximumBorrowPlan = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: borrowMaximum}));
        bytes memory tooHighYieldPlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: tooHighYield}));
        bytes memory tooHighBorrowPlan = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: tooHighBorrow}));

        vm.prank(admin);
        uint256 yieldPlanId = tracker.createPlan(YIELD_FEE, maximumYieldPlan);
        vm.prank(admin);
        uint256 borrowPlanId = tracker.createPlan(BORROW_FEE, maximumBorrowPlan);

        assertEq(yieldPlanId, 1);
        assertEq(borrowPlanId, 1);
        YieldSeekerYieldFeeModule.Plan memory storedMaximumYieldPlan = abi.decode(tracker.plan(YIELD_FEE, yieldPlanId), (YieldSeekerYieldFeeModule.Plan));
        YieldSeekerBorrowFeeModule.Plan memory storedMaximumBorrowPlan = abi.decode(tracker.plan(BORROW_FEE, borrowPlanId), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(storedMaximumYieldPlan.rateBps, yieldMaximum);
        assertEq(storedMaximumBorrowPlan.rateBps, borrowMaximum);
        assertEq(tracker.planCount(YIELD_FEE), 2);
        assertEq(tracker.planCount(BORROW_FEE), 2);
        FeePlanChoice[] memory maximumPlan = new FeePlanChoice[](1);
        maximumPlan[0] = FeePlanChoice({feeType: YIELD_FEE, planId: yieldPlanId});
        tracker.initWalletPlans(address(wallet), maximumPlan);
        _recordYield(wallet, 10_000);
        assertEq(vaultModule.feesOwed(address(wallet)), 2_000);

        uint256 invalidYieldPlanId = tracker.planCount(YIELD_FEE);
        uint256 invalidBorrowPlanId = tracker.planCount(BORROW_FEE);
        bytes memory invalidYieldPlanError = abi.encodeWithSelector(InvalidPlan.selector, YIELD_FEE, invalidYieldPlanId);
        bytes memory invalidBorrowPlanError = abi.encodeWithSelector(InvalidPlan.selector, BORROW_FEE, invalidBorrowPlanId);
        vm.expectRevert(invalidYieldPlanError);
        vm.prank(admin);
        tracker.createPlan(YIELD_FEE, tooHighYieldPlan);

        vm.expectRevert(invalidBorrowPlanError);
        vm.prank(admin);
        tracker.createPlan(BORROW_FEE, tooHighBorrowPlan);

        bytes32 unknownFeeType = keccak256("unknown");
        bytes memory unknownFeePlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 0}));
        bytes memory unknownFeeTypeError = abi.encodeWithSelector(UnknownFeeType.selector, unknownFeeType);
        vm.expectRevert(unknownFeeTypeError);
        vm.prank(admin);
        tracker.createPlan(unknownFeeType, unknownFeePlan);
    }

    function testInitWalletPlansRequiresFactoryAndRejectsUnknownPlans() public {
        address stranger = makeAddr("stranger");
        FeePlanChoice[] memory plans = new FeePlanChoice[](1);
        plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 1});

        bytes memory unauthorizedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger);
        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        tracker.initWalletPlans(address(wallet), plans);

        bytes memory unknownPlanError = abi.encodeWithSelector(UnknownPlan.selector, YIELD_FEE, 99);
        plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 99});
        vm.expectRevert(unknownPlanError);
        tracker.initWalletPlans(address(wallet), plans);

        assertEq(tracker.walletPlanId(address(wallet), YIELD_FEE), 0);
    }

    function testSetWalletFactoryIsAdminOnlyAndRequiresContract() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert();
        vm.prank(stranger);
        tracker.setWalletFactory(address(this));

        bytes memory notAContractError = abi.encodeWithSelector(AWKErrors.NotAContract.selector, stranger);
        vm.expectRevert(notAContractError);
        vm.prank(admin);
        tracker.setWalletFactory(stranger);

        assertEq(tracker.walletFactory(), address(this));
    }

    function testReportActionCapsModulesToRemainingBalanceAndReturnsCollector() public {
        bytes32 market = keccak256("market");
        bytes memory borrowedData = abi.encode(FeeActions.DebtChange({market: market, debtToken: address(debtToken), debtBefore: 0, borrowed: 100, repaid: 0}));
        _reportAction(wallet, FeeActions.DEBT_CHANGE, borrowedData);

        uint256 start = vm.getBlockTimestamp();
        uint256 checkpointTime = start + 365 days;
        vm.warp(checkpointTime);
        bytes memory checkpointData = abi.encode(FeeActions.DebtChange({market: market, debtToken: address(debtToken), debtBefore: 100, borrowed: 0, repaid: 0}));
        _reportAction(wallet, FeeActions.DEBT_CHANGE, checkpointData);
        _recordYield(wallet, 100);

        assertEq(borrowModule.feesOwed(address(wallet), address(debtToken)), 3);
        assertEq(vaultModule.feesOwed(address(wallet)), 10);
        baseAsset.mint(address(wallet), 8);

        (uint256 payment, address actualCollector) = _reportAction(wallet, bytes32(0), bytes(""));

        assertEq(payment, 8);
        assertEq(actualCollector, collector);
        assertEq(borrowModule.feesOwed(address(wallet), address(debtToken)), 0);
        assertEq(vaultModule.feesOwed(address(wallet)), 5);
    }

    function testWalletRatesUsePerFeeTypePlansAndAreKeyedByWallet() public {
        MockFeeWallet secondWallet = new MockFeeWallet(ownerA, IERC20(address(baseAsset)));
        bytes memory yieldPlanData = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 500}));
        bytes memory borrowPlanData = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 400}));
        vm.prank(admin);
        uint256 yieldPlanId = tracker.createPlan(YIELD_FEE, yieldPlanData);
        vm.prank(admin);
        uint256 borrowPlanId = tracker.createPlan(BORROW_FEE, borrowPlanData);

        FeePlanChoice[] memory plans = new FeePlanChoice[](2);
        plans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: yieldPlanId});
        plans[1] = FeePlanChoice({feeType: BORROW_FEE, planId: borrowPlanId});
        tracker.initWalletPlans(address(wallet), plans);

        assertEq(vaultModule.walletPlan(address(wallet)).rateBps, 500);
        assertEq(borrowModule.walletPlan(address(wallet)).rateBps, 400);
        assertEq(vaultModule.walletPlan(address(secondWallet)).rateBps, 1_000);
        assertEq(borrowModule.walletPlan(address(secondWallet)).rateBps, 300);
        assertEq(tracker.walletPlanId(address(wallet), YIELD_FEE), yieldPlanId);
        assertEq(tracker.walletPlanId(address(secondWallet), YIELD_FEE), 0);
        bytes32 unconfiguredFeeType = keccak256("unconfigured");
        assertEq(tracker.walletPlan(address(wallet), unconfiguredFeeType).length, 0);

        _recordYield(wallet, 10e6);
        _recordYield(secondWallet, 10e6);

        assertEq(vaultModule.feesOwed(address(wallet)), 500_000);
        assertEq(vaultModule.feesOwed(address(secondWallet)), 1_000_000);
    }

    function testModuleReplacementMustSupportEveryExistingPlanRate() public {
        bytes memory additionalPlan = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 500}));
        vm.prank(admin);
        uint256 planId = tracker.createPlan(BORROW_FEE, additionalPlan);
        assertEq(planId, 1);

        YieldSeekerBorrowFeeModule replacement = new YieldSeekerBorrowFeeModule(tracker, oracle, 750);
        vm.prank(admin);
        tracker.setFeeModule(BORROW_FEE, replacement);

        YieldSeekerBorrowFeeModule tooSmall = new YieldSeekerBorrowFeeModule(tracker, oracle, 299);
        bytes memory unsupportedPlanError = abi.encodeWithSelector(InvalidPlan.selector, BORROW_FEE, 0);
        vm.expectRevert(unsupportedPlanError);
        vm.prank(admin);
        tracker.setFeeModule(BORROW_FEE, tooSmall);

        assertEq(address(tracker.feeModules(BORROW_FEE)), address(replacement));
        YieldSeekerBorrowFeeModule.Plan memory storedPlan = abi.decode(tracker.plan(BORROW_FEE, planId), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(storedPlan.rateBps, 500);
        assertEq(tracker.planCount(BORROW_FEE), 2);

        bytes32[] memory feeTypes = tracker.moduleFeeTypes();
        assertEq(feeTypes.length, 2);
        assertEq(feeTypes[0], BORROW_FEE);
        assertEq(feeTypes[1], YIELD_FEE);
    }

    function testHigherMaximumReplacementPreservesPlansAndWalletRates() public {
        bytes memory existingPlanData = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 500}));
        vm.prank(admin);
        uint256 existingPlanId = tracker.createPlan(BORROW_FEE, existingPlanData);
        FeePlanChoice[] memory walletPlans = new FeePlanChoice[](1);
        walletPlans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: existingPlanId});
        tracker.initWalletPlans(address(wallet), walletPlans);
        YieldSeekerBorrowFeeModule replacement = new YieldSeekerBorrowFeeModule(tracker, oracle, 750);
        vm.prank(admin);
        tracker.setFeeModule(BORROW_FEE, replacement);

        YieldSeekerBorrowFeeModule.Plan memory originalDefaultPlan = abi.decode(tracker.plan(BORROW_FEE, 0), (YieldSeekerBorrowFeeModule.Plan));
        YieldSeekerBorrowFeeModule.Plan memory originalAssignedPlan = abi.decode(tracker.plan(BORROW_FEE, existingPlanId), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(originalDefaultPlan.rateBps, 300);
        assertEq(originalAssignedPlan.rateBps, 500);
        assertEq(replacement.walletPlan(address(wallet)).rateBps, 500);

        bytes memory newPlanData = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 600}));
        assertFalse(borrowModule.isValidPlan(newPlanData));
        assertTrue(replacement.isValidPlan(newPlanData));
        vm.prank(admin);
        uint256 newPlanId = tracker.createPlan(BORROW_FEE, newPlanData);
        assertEq(newPlanId, 2);
        YieldSeekerBorrowFeeModule.Plan memory newPlan = abi.decode(tracker.plan(BORROW_FEE, newPlanId), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(newPlan.rateBps, 600);
    }

    function testSetFeeModuleRejectsModuleBuiltForAnotherTracker() public {
        bytes32 feeType = PROBE_FEE;
        YieldSeekerFeeTracker otherTracker = new YieldSeekerFeeTracker(admin, collector);
        FeeTrackerProbeModule module = new FeeTrackerProbeModule(address(otherTracker), feeType, address(wallet), PROBE_TOKEN, 0);
        bytes memory expectedError = abi.encodeWithSelector(InvalidFeeModule.selector, feeType, address(module));

        vm.expectRevert(expectedError);
        vm.prank(admin);
        tracker.setFeeModule(feeType, module);
    }

    function testSetFeeModuleRejectsModuleBuiltForAnotherFeeType() public {
        bytes32 feeType = PROBE_FEE;
        FeeTrackerProbeModule module = new FeeTrackerProbeModule(address(tracker), REVERTING_FEE, address(wallet), PROBE_TOKEN, 0);
        bytes memory expectedError = abi.encodeWithSelector(InvalidFeeModule.selector, feeType, address(module));

        vm.expectRevert(expectedError);
        vm.prank(admin);
        tracker.setFeeModule(feeType, module);
    }

    function testReportActionRevertsWhenModuleExceedsAvailable() public {
        bytes32 feeType = keccak256("overpaying");
        FeeTrackerOverpayingModule overpayingModule = new FeeTrackerOverpayingModule(address(tracker), feeType);
        uint256 available = baseAsset.balanceOf(address(wallet));
        uint256 payment = available + 1;
        bytes memory expectedError = abi.encodeWithSelector(PaymentExceedsAvailable.selector, address(overpayingModule), payment, available);

        vm.prank(admin);
        tracker.setFeeModule(feeType, overpayingModule);
        vm.expectRevert(expectedError);
        vm.prank(address(wallet));
        tracker.reportAction(bytes32(0), bytes(""));
    }

    function testIsAccountedTokenAndFeesOwedInBaseAssetAggregateModulesAndIgnoreFailures() public {
        FeeTrackerProbeModule probe = new FeeTrackerProbeModule(address(tracker), PROBE_FEE, address(wallet), PROBE_TOKEN, 123);
        FeeTrackerHostileModule revertingModule = new FeeTrackerHostileModule(address(tracker), REVERTING_FEE, false);
        FeeTrackerHostileModule gasBurningModule = new FeeTrackerHostileModule(address(tracker), GAS_BURNING_FEE, true);

        _recordYield(wallet, 100e6);
        _recordDebtChange(wallet, keccak256("market"), address(debtToken), 0, 1_000, 0);

        vm.startPrank(admin);
        tracker.setFeeModule(REVERTING_FEE, revertingModule);
        tracker.setFeeModule(GAS_BURNING_FEE, gasBurningModule);
        tracker.setFeeModule(PROBE_FEE, probe);
        vm.stopPrank();

        assertTrue(tracker.isAccountedToken(address(wallet), address(baseAsset)));
        assertTrue(tracker.isAccountedToken(address(wallet), address(debtToken)));
        assertTrue(tracker.isAccountedToken(address(wallet), PROBE_TOKEN));
        assertFalse(tracker.isAccountedToken(address(wallet), UNTRACKED_TOKEN));
        assertEq(tracker.feesOwedInBaseAsset(address(wallet)), 10e6 + 123);
    }

    function testFeesOwedInBaseAssetRevertsWhenCallerCannotProvideModuleGas() public {
        vm.expectRevert(InsufficientGasForModules.selector);
        tracker.feesOwedInBaseAsset{gas: 50_000}(address(wallet));
    }

    function testFeeCollectorCanBeUpdatedByAdmin() public {
        address newCollector = makeAddr("newCollector");
        vm.prank(admin);
        tracker.setFeeCollector(newCollector);
        assertEq(tracker.feeCollector(), newCollector);
    }

    function _reportAction(MockFeeWallet targetWallet, bytes32 action, bytes memory data) internal returns (uint256 payment, address feeCollector) {
        bytes memory returnData = targetWallet.execute(address(tracker), abi.encodeCall(tracker.reportAction, (action, data)));
        return abi.decode(returnData, (uint256, address));
    }

    function _recordYield(MockFeeWallet targetWallet, uint256 amount) internal {
        _reportAction(targetWallet, FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(baseAsset), amount: amount})));
    }

    function _recordDebtChange(MockFeeWallet targetWallet, bytes32 market, address token, uint256 debtBefore, uint256 borrowed, uint256 repaid) internal {
        _reportAction(targetWallet, FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: token, debtBefore: debtBefore, borrowed: borrowed, repaid: repaid})));
    }
}
