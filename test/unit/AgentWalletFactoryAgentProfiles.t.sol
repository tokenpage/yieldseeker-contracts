// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {AgentAlreadyExists, InvalidImplementationFactory, UnknownAgentProfile} from "../../src/agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {FeePlanChoice, UnknownPlan, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {IYieldSeekerSwapPolicy} from "../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy} from "../../src/swaps/VaultSwapPolicy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

contract AgentWalletFactoryAgentProfilesTest is Test {
    bytes32 private constant VAULT_AGENT_PROFILE = keccak256("vault");
    bytes32 private constant BORROW_AGENT_PROFILE = keccak256("borrow");

    address private constant OPERATOR = address(0xA11CE);
    address private constant STRANGER = address(0xB0B);
    address private constant FEE_COLLECTOR_A = address(0xCAFE);

    MockERC20 private baseAsset;
    YieldSeekerAdapterRegistry private registryVault;
    YieldSeekerAdapterRegistry private registryBorrow;
    YieldSeekerFeeTracker private feeVault;
    YieldSeekerFeeTracker private feeBorrowTracker;
    YieldSeekerYieldFeeModule private feeYield;
    YieldSeekerYieldFeeModule private feeBorrowYield;
    YieldSeekerBorrowFeeModule private feeBorrow;
    YieldSeekerAgentWalletFactory private factory;

    event FeeTrackerUpdated(bytes32 indexed agentProfile, address indexed oldFeeTracker, address indexed newFeeTracker);
    event SwapPolicyUpdated(bytes32 indexed agentProfile, address indexed oldSwapPolicy, address indexed newSwapPolicy);

    function setUp() public {
        baseAsset = new MockERC20("Base Asset", "BASE");
        registryVault = new YieldSeekerAdapterRegistry(address(this), address(this));
        registryBorrow = new YieldSeekerAdapterRegistry(address(this), address(this));
        feeVault = new YieldSeekerFeeTracker(address(this), FEE_COLLECTOR_A);
        feeYield = new YieldSeekerYieldFeeModule(feeVault, 10_000);
        feeVault.setFeeModule(YIELD_FEE, feeYield);
        feeVault.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 750})));
        feeBorrowTracker = new YieldSeekerFeeTracker(address(this), FEE_COLLECTOR_A);
        feeBorrowYield = new YieldSeekerYieldFeeModule(feeBorrowTracker, 10_000);
        feeBorrowTracker.setFeeModule(YIELD_FEE, feeBorrowYield);
        feeBorrowTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 1_000})));
        feeBorrow = new YieldSeekerBorrowFeeModule(feeBorrowTracker, 500);
        feeBorrowTracker.setFeeModule(BORROW_FEE, feeBorrow);
        feeBorrowTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 500})));
        feeBorrowTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 250})));
        factory = new YieldSeekerAgentWalletFactory(address(this), OPERATOR);
        feeVault.setWalletFactory(address(factory));
        feeBorrowTracker.setWalletFactory(address(factory));

        YieldSeekerAgentWalletV3 implementation = new YieldSeekerAgentWalletV3(address(factory));
        factory.setAgentWalletImplementation(implementation);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registryVault);
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, registryBorrow);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, feeVault);
        factory.setFeeTracker(BORROW_AGENT_PROFILE, feeBorrowTracker);
    }

    function test_CreatedWalletsUseTheirAgentProfileRegistryAndFeeTracker() public {
        address walletOwner = makeAddr("wallet-owner");
        uint256 vaultIndex = 3;
        uint256 borrowIndex = 4;

        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.startPrank(OPERATOR);
        YieldSeekerAgentWalletV3 vaultWallet = factory.createAgentWallet(walletOwner, vaultIndex, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);
        YieldSeekerAgentWalletV3 borrowWallet = factory.createAgentWallet(walletOwner, borrowIndex, address(baseAsset), BORROW_AGENT_PROFILE, noFeePlans);
        vm.stopPrank();

        assertEq(address(vaultWallet), factory.getAddress(walletOwner, vaultIndex));
        assertEq(address(borrowWallet), factory.getAddress(walletOwner, borrowIndex));
        assertEq(factory.userWallets(walletOwner, vaultIndex), address(vaultWallet));
        assertEq(factory.userWallets(walletOwner, borrowIndex), address(borrowWallet));
        assertEq(vaultWallet.agentProfile(), VAULT_AGENT_PROFILE);
        assertEq(borrowWallet.agentProfile(), BORROW_AGENT_PROFILE);
        assertEq(address(vaultWallet.adapterRegistry()), address(registryVault));
        assertEq(address(borrowWallet.adapterRegistry()), address(registryBorrow));
        assertEq(address(vaultWallet.feeTracker()), address(feeVault));
        assertEq(address(borrowWallet.feeTracker()), address(feeBorrowTracker));
        assertEq(address(feeVault.feeModules(BORROW_FEE)), address(0));
        assertEq(address(feeBorrowTracker.feeModules(BORROW_FEE)), address(feeBorrow));
        bytes32[] memory vaultFeeTypes = feeVault.moduleFeeTypes();
        assertEq(vaultFeeTypes.length, 1);
        assertEq(vaultFeeTypes[0], YIELD_FEE);
        bytes32[] memory borrowFeeTypes = feeBorrowTracker.moduleFeeTypes();
        assertEq(borrowFeeTypes.length, 2);
        assertEq(borrowFeeTypes[0], YIELD_FEE);
        assertEq(borrowFeeTypes[1], BORROW_FEE);
    }

    function test_BorrowWalletUsesBorrowTrackerForBorrowFeesAndTokenAccounting() public {
        MockERC20 borrowedToken = new MockERC20("Borrowed", "BORROWED");
        address walletOwner = makeAddr("borrow-accounting-wallet-owner");
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.startPrank(OPERATOR);
        YieldSeekerAgentWalletV3 vaultWallet = factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);
        YieldSeekerAgentWalletV3 borrowWallet = factory.createAgentWallet(walletOwner, 2, address(baseAsset), BORROW_AGENT_PROFILE, noFeePlans);
        vm.stopPrank();

        uint256 startTime = vm.getBlockTimestamp();
        if (startTime == 0) {
            vm.warp(1);
            startTime = vm.getBlockTimestamp();
        }
        uint256 elapsed = 365 days;
        uint256 rateBps = feeBorrow.walletPlan(address(borrowWallet)).rateBps;
        uint256 expectedFee = (100e6 * rateBps * elapsed) / (365 days * 10_000);
        bytes32 market = keccak256("profile-tracker-market");
        bytes memory initialDebt = abi.encode(FeeActions.DebtChange({market: market, debtToken: address(borrowedToken), debtBefore: 0, borrowed: 100e6, repaid: 0, debtPriceInBaseAsset: 0}));
        bytes memory accruedDebt = abi.encode(FeeActions.DebtChange({market: market, debtToken: address(borrowedToken), debtBefore: 100e6, borrowed: 0, repaid: 0, debtPriceInBaseAsset: 1e36}));

        vm.prank(address(borrowWallet));
        feeBorrowTracker.reportAction(FeeActions.DEBT_CHANGE, initialDebt);
        vm.warp(startTime + elapsed);
        vm.prank(address(borrowWallet));
        feeBorrowTracker.reportAction(FeeActions.DEBT_CHANGE, accruedDebt);

        assertEq(feeBorrow.feesOwed(address(borrowWallet)), expectedFee);
        assertTrue(feeBorrowTracker.isAccountedToken(address(borrowWallet), address(borrowedToken)));
        assertFalse(feeVault.isAccountedToken(address(vaultWallet), address(borrowedToken)));
    }

    function test_CreatedWalletFeePlansArePerTrackerAndUsePlanZeroForUnlistedTypes() public {
        address walletOwner = makeAddr("fee-plan-wallet-owner");
        FeePlanChoice[] memory vaultPlans = new FeePlanChoice[](1);
        vaultPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: 0});
        FeePlanChoice[] memory borrowPlans = new FeePlanChoice[](1);
        borrowPlans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: 1});
        vm.startPrank(OPERATOR);
        YieldSeekerAgentWalletV3 vaultWallet = factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, vaultPlans);
        YieldSeekerAgentWalletV3 borrowWallet = factory.createAgentWallet(walletOwner, 2, address(baseAsset), BORROW_AGENT_PROFILE, borrowPlans);
        vm.stopPrank();

        assertEq(feeYield.walletPlan(address(vaultWallet)).rateBps, 750);
        assertEq(feeBorrowYield.walletPlan(address(borrowWallet)).rateBps, 1_000);
        assertEq(feeBorrow.walletPlan(address(borrowWallet)).rateBps, 250);
        assertEq(feeVault.walletPlanId(address(vaultWallet), YIELD_FEE), 0);
        assertEq(feeBorrowTracker.walletPlanId(address(borrowWallet), BORROW_FEE), 1);
        assertEq(feeBorrowTracker.walletPlanId(address(borrowWallet), YIELD_FEE), 0);
    }

    function test_CreateAgentWalletRejectsUnknownFeePlan() public {
        address walletOwner = makeAddr("unknown-fee-plan-wallet-owner");
        FeePlanChoice[] memory plans = new FeePlanChoice[](1);
        plans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: 2});
        bytes memory expectedError = abi.encodeWithSelector(UnknownPlan.selector, BORROW_FEE, 2);

        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), BORROW_AGENT_PROFILE, plans);
    }

    function test_CreateAgentWalletWithFeePlansRequiresWalletFactory() public {
        address walletOwner = makeAddr("unprivileged-fee-plan-wallet-owner");
        FeePlanChoice[] memory plans = new FeePlanChoice[](1);
        plans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: 0});
        bytes memory expectedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, address(factory));

        feeBorrowTracker.setWalletFactory(address(feeBorrow));
        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), BORROW_AGENT_PROFILE, plans);
    }

    function test_CreateAgentWalletRequiresOperatorRole() public {
        address walletOwner = makeAddr("wallet-owner");
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        bytes memory expectedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, operatorRole);
        vm.prank(STRANGER);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);
    }

    function test_CreateAgentWalletRejectsUnknownAgentProfile() public {
        bytes32 unknown = keccak256("missing-agent-profile");
        address walletOwner = makeAddr("wallet-owner");
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        bytes memory expectedError = abi.encodeWithSelector(UnknownAgentProfile.selector, unknown);
        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), unknown, noFeePlans);
    }

    function test_FactoryProfileConfigurationValidatesAccessAndEmitsEvents() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, adminRole);
        YieldSeekerFeeTracker nextTracker = new YieldSeekerFeeTracker(address(this), FEE_COLLECTOR_A);
        YieldSeekerSwapSellPolicy sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        YieldSeekerVaultSwapPolicy nextPolicy = new YieldSeekerVaultSwapPolicy(sellPolicy);
        address notAContract = address(0x1234);
        bytes memory nonContractError = abi.encodeWithSelector(AWKErrors.NotAContract.selector, notAContract);
        bytes memory zeroProfileError = abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(0));
        bytes memory zeroTrackerError = abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0));

        vm.prank(STRANGER);
        vm.expectRevert(unauthorizedError);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, nextTracker);
        vm.prank(STRANGER);
        vm.expectRevert(unauthorizedError);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, nextPolicy);

        vm.expectRevert(zeroProfileError);
        factory.setFeeTracker(bytes32(0), nextTracker);
        vm.expectRevert(zeroProfileError);
        factory.setSwapPolicy(bytes32(0), nextPolicy);
        vm.expectRevert(zeroProfileError);
        factory.setAdapterRegistry(bytes32(0), registryVault);

        vm.expectRevert(nonContractError);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, YieldSeekerFeeTracker(notAContract));
        vm.expectRevert(nonContractError);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, IYieldSeekerSwapPolicy(notAContract));
        vm.expectRevert(zeroTrackerError);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, YieldSeekerFeeTracker(address(0)));

        address previousTracker = address(factory.feeTracker(VAULT_AGENT_PROFILE));
        vm.expectEmit(true, true, true, true, address(factory));
        emit FeeTrackerUpdated(VAULT_AGENT_PROFILE, previousTracker, address(nextTracker));
        factory.setFeeTracker(VAULT_AGENT_PROFILE, nextTracker);
        assertEq(address(factory.feeTracker(VAULT_AGENT_PROFILE)), address(nextTracker));

        address previousPolicy = address(factory.swapPolicy(VAULT_AGENT_PROFILE));
        vm.expectEmit(true, true, true, true, address(factory));
        emit SwapPolicyUpdated(VAULT_AGENT_PROFILE, previousPolicy, address(nextPolicy));
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, nextPolicy);
        assertEq(address(factory.swapPolicy(VAULT_AGENT_PROFILE)), address(nextPolicy));
    }

    function test_DuplicateOwnerIndexReverts() public {
        address walletOwner = makeAddr("wallet-owner");
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        bytes memory expectedError = abi.encodeWithSelector(AgentAlreadyExists.selector, walletOwner, 8);
        vm.prank(OPERATOR);
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);

        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), BORROW_AGENT_PROFILE, noFeePlans);
    }

    function test_ImplementationBoundToAnotherFactoryIsRejected() public {
        YieldSeekerAgentWalletFactory otherFactory = new YieldSeekerAgentWalletFactory(address(this), STRANGER);
        YieldSeekerAgentWalletV3 foreignImplementation = new YieldSeekerAgentWalletV3(address(otherFactory));

        vm.expectRevert(InvalidImplementationFactory.selector);
        factory.setAgentWalletImplementation(foreignImplementation);
    }
}
