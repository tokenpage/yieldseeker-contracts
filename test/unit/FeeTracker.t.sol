// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IAccessControl} from "../../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, InvalidFeeModule, InvalidPlan, PaymentExceedsAvailable, UnknownFeeType, UnknownPlan, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerOverpayingModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address tracker, bytes32 feeType) {
        FEE_TRACKER = tracker;
        FEE_TYPE = feeType;
    }

    function isValidPlan(bytes calldata plan) external pure override returns (bool) {
        return plan.length == 32;
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
    bytes32 private constant OVERPAYING_FEE = keccak256("overpaying");

    address private admin;
    address private collector = makeAddr("collector");
    address private owner = makeAddr("owner");

    MockERC20 private baseAsset;
    MockFeeWallet private wallet;
    YieldSeekerFeeTracker private tracker;
    YieldSeekerYieldFeeModule private yieldModule;
    YieldSeekerBorrowFeeModule private borrowModule;

    function setUp() public {
        admin = address(this);
        baseAsset = new MockERC20("Base", "BASE");
        wallet = new MockFeeWallet(owner, IERC20(address(baseAsset)));
        tracker = new YieldSeekerFeeTracker(admin, collector);
        yieldModule = new YieldSeekerYieldFeeModule(tracker, 2_000);
        borrowModule = new YieldSeekerBorrowFeeModule(tracker, 500);
        tracker.setFeeModule(YIELD_FEE, yieldModule);
        tracker.setFeeModule(BORROW_FEE, borrowModule);
        tracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 1_000})));
        tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 300})));
        tracker.setWalletFactory(address(this));
    }

    function testPlansAreNumberedPerFeeTypeAndValidatedAtModuleMaximum() public {
        assertEq(tracker.planCount(YIELD_FEE), 1);
        assertEq(tracker.planCount(BORROW_FEE), 1);
        YieldSeekerYieldFeeModule.Plan memory storedYieldPlan = abi.decode(tracker.plan(YIELD_FEE, 0), (YieldSeekerYieldFeeModule.Plan));
        YieldSeekerBorrowFeeModule.Plan memory storedBorrowPlan = abi.decode(tracker.plan(BORROW_FEE, 0), (YieldSeekerBorrowFeeModule.Plan));
        assertEq(storedYieldPlan.rateBps, 1_000);
        assertEq(storedBorrowPlan.rateBps, 300);

        uint256 yieldMaximum = yieldModule.MAX_FEE_RATE_BPS();
        uint256 borrowMaximum = borrowModule.MAX_FEE_RATE_BPS();
        uint256 yieldPlanId = tracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: yieldMaximum})));
        uint256 borrowPlanId = tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: borrowMaximum})));
        assertEq(yieldPlanId, 1);
        assertEq(borrowPlanId, 1);

        uint256 invalidYieldPlanId = tracker.planCount(YIELD_FEE);
        uint256 invalidBorrowPlanId = tracker.planCount(BORROW_FEE);
        bytes memory invalidYieldPlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: yieldMaximum + 1}));
        bytes memory invalidBorrowPlan = abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: borrowMaximum + 1}));
        vm.expectRevert(abi.encodeWithSelector(InvalidPlan.selector, YIELD_FEE, invalidYieldPlanId));
        tracker.createPlan(YIELD_FEE, invalidYieldPlan);
        vm.expectRevert(abi.encodeWithSelector(InvalidPlan.selector, BORROW_FEE, invalidBorrowPlanId));
        tracker.createPlan(BORROW_FEE, invalidBorrowPlan);

        bytes32 unknownFeeType = keccak256("unknown");
        bytes memory unknownFeePlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 0}));
        vm.expectRevert(abi.encodeWithSelector(UnknownFeeType.selector, unknownFeeType));
        tracker.createPlan(unknownFeeType, unknownFeePlan);

        vm.expectRevert(abi.encodeWithSelector(UnknownPlan.selector, YIELD_FEE, invalidYieldPlanId));
        tracker.plan(YIELD_FEE, invalidYieldPlanId);
    }

    function testWalletPlanInitializationIsFactoryOnlyAndRejectsUnknownPlan() public {
        address stranger = makeAddr("stranger");
        FeePlanChoice[] memory choices = new FeePlanChoice[](1);
        choices[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tracker.initWalletPlans(address(wallet), choices);

        choices[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 99});
        vm.expectRevert(abi.encodeWithSelector(UnknownPlan.selector, YIELD_FEE, 99));
        tracker.initWalletPlans(address(wallet), choices);
        assertEq(tracker.walletPlanId(address(wallet), YIELD_FEE), 0);
    }

    function testConfigurationIsAdminOnlyAndWalletFactoryMustBeAContract() public {
        address stranger = makeAddr("stranger");
        bytes memory unauthorized = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, bytes32(0));
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        tracker.setFeeCollector(stranger);
        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        tracker.setFeeModule(BORROW_FEE, borrowModule);

        vm.expectRevert(unauthorized);
        vm.prank(stranger);
        tracker.setWalletFactory(address(this));

        bytes memory notAContract = abi.encodeWithSelector(AWKErrors.NotAContract.selector, stranger);
        vm.expectRevert(notAContract);
        tracker.setWalletFactory(stranger);
        assertEq(tracker.walletFactory(), address(this));
    }

    function testReplacementModuleMustMatchTrackerAndAcceptEveryExistingPlan() public {
        uint256 additionalPlanId = tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 500})));
        assertEq(additionalPlanId, 1);
        FeePlanChoice[] memory walletPlans = new FeePlanChoice[](1);
        walletPlans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: additionalPlanId});
        tracker.initWalletPlans(address(wallet), walletPlans);

        YieldSeekerBorrowFeeModule replacement = new YieldSeekerBorrowFeeModule(tracker, 750);
        tracker.setFeeModule(BORROW_FEE, replacement);
        uint256 newPlanId = tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 600})));
        assertEq(newPlanId, 2);

        YieldSeekerBorrowFeeModule tooSmall = new YieldSeekerBorrowFeeModule(tracker, 299);
        vm.expectRevert(abi.encodeWithSelector(InvalidPlan.selector, BORROW_FEE, 0));
        tracker.setFeeModule(BORROW_FEE, tooSmall);
        assertEq(address(tracker.feeModules(BORROW_FEE)), address(replacement));

        YieldSeekerFeeTracker otherTracker = new YieldSeekerFeeTracker(admin, collector);
        YieldSeekerBorrowFeeModule wrongTracker = new YieldSeekerBorrowFeeModule(otherTracker, 750);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeModule.selector, BORROW_FEE, address(wrongTracker)));
        tracker.setFeeModule(BORROW_FEE, wrongTracker);

        YieldSeekerBorrowFeeModule wrongType = new YieldSeekerBorrowFeeModule(tracker, 750);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeModule.selector, YIELD_FEE, address(wrongType)));
        tracker.setFeeModule(YIELD_FEE, wrongType);
    }

    function testReportActionRejectsFakeModuleThatExceedsAvailableBalance() public {
        FeeTrackerOverpayingModule module = new FeeTrackerOverpayingModule(address(tracker), OVERPAYING_FEE);
        tracker.setFeeModule(OVERPAYING_FEE, module);
        uint256 available = 100;
        baseAsset.mint(address(wallet), available);
        uint256 payment = available + 1;
        bytes memory expected = abi.encodeWithSelector(PaymentExceedsAvailable.selector, address(module), payment, available);
        vm.expectRevert(expected);
        wallet.execute(address(tracker), abi.encodeCall(tracker.reportAction, (bytes32(0), bytes(""))));
    }
}
