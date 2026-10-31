// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {AgentAlreadyExists, InvalidImplementationFactory, UnknownAgentProfile} from "../../src/agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlan, UnknownPlan, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapAdapterPriceOracle} from "../mocks/MockSwapAdapterPriceOracle.sol";
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
    YieldSeekerYieldFeeModule private feeYield;
    YieldSeekerBorrowFeeModule private feeBorrow;
    YieldSeekerAgentWalletFactory private factory;

    function setUp() public {
        baseAsset = new MockERC20("Base Asset", "BASE");
        registryVault = new YieldSeekerAdapterRegistry(address(this), address(this));
        registryBorrow = new YieldSeekerAdapterRegistry(address(this), address(this));
        feeVault = new YieldSeekerFeeTracker(address(this), FEE_COLLECTOR_A);
        feeBorrow = new YieldSeekerBorrowFeeModule(feeVault, new MockSwapAdapterPriceOracle(), 500);
        feeVault.setFeeModule(BORROW_FEE, feeBorrow);
        feeVault.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 500})));
        feeVault.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 250})));
        feeYield = new YieldSeekerYieldFeeModule(feeVault, 1_000);
        feeVault.setFeeModule(YIELD_FEE, feeYield);
        feeVault.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 750})));
        factory = new YieldSeekerAgentWalletFactory(address(this), OPERATOR);

        YieldSeekerAgentWalletV3 implementation = new YieldSeekerAgentWalletV3(address(factory));
        factory.setAgentWalletImplementation(implementation);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registryVault);
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, registryBorrow);
        factory.setFeeTracker(feeVault);
    }

    function test_CreatedWalletsUseTheirAgentProfileRegistryAndTheSharedFeeTracker() public {
        address walletOwner = makeAddr("wallet-owner");
        uint256 vaultIndex = 3;
        uint256 borrowIndex = 4;

        FeePlan[] memory noFeePlans = new FeePlan[](0);
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
        assertEq(address(borrowWallet.feeTracker()), address(feeVault));
        assertEq(address(feeVault.feeModules(BORROW_FEE)), address(feeBorrow));
    }

    function test_CreatedWalletFeePlansSetRatesAndUsePlanZeroForUnlistedTypes() public {
        address walletOwner = makeAddr("fee-plan-wallet-owner");
        FeePlan[] memory plans = new FeePlan[](1);
        plans[0] = FeePlan({feeType: BORROW_FEE, planId: 1});
        feeVault.grantRole(feeVault.WALLET_FACTORY_ROLE(), address(factory));
        vm.prank(OPERATOR);
        YieldSeekerAgentWalletV3 wallet = factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, plans);

        assertEq(feeBorrow.walletPlan(address(wallet)).rateBps, 250);
        assertEq(feeYield.walletPlan(address(wallet)).rateBps, 750);
        assertEq(feeVault.walletPlanId(address(wallet), BORROW_FEE), 1);
        assertEq(feeVault.walletPlanId(address(wallet), YIELD_FEE), 0);
    }

    function test_CreateAgentWalletRejectsUnknownFeePlan() public {
        address walletOwner = makeAddr("unknown-fee-plan-wallet-owner");
        FeePlan[] memory plans = new FeePlan[](1);
        plans[0] = FeePlan({feeType: BORROW_FEE, planId: 2});
        bytes memory expectedError = abi.encodeWithSelector(UnknownPlan.selector, BORROW_FEE, 2);
        feeVault.grantRole(feeVault.WALLET_FACTORY_ROLE(), address(factory));

        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, plans);
    }

    function test_CreateAgentWalletWithFeePlansRequiresFactoryRole() public {
        address walletOwner = makeAddr("unprivileged-fee-plan-wallet-owner");
        FeePlan[] memory plans = new FeePlan[](1);
        plans[0] = FeePlan({feeType: BORROW_FEE, planId: 0});
        bytes32 factoryRole = feeVault.WALLET_FACTORY_ROLE();
        bytes memory expectedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(factory), factoryRole);
        assertFalse(feeVault.hasRole(factoryRole, address(factory)));

        vm.prank(OPERATOR);
        vm.expectRevert(expectedError);
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, plans);
    }

    function test_CreateAgentWalletRequiresOperatorRole() public {
        address walletOwner = makeAddr("wallet-owner");
        FeePlan[] memory noFeePlans = new FeePlan[](0);
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, operatorRole));
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);
    }

    function test_CreateAgentWalletRejectsUnknownAgentProfile() public {
        bytes32 unknown = keccak256("missing-agent-profile");
        address walletOwner = makeAddr("wallet-owner");
        FeePlan[] memory noFeePlans = new FeePlan[](0);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, unknown));
        factory.createAgentWallet(walletOwner, 1, address(baseAsset), unknown, noFeePlans);
    }

    function test_AgentProfileZeroAndZeroFeeTrackerAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(0)));
        factory.setAdapterRegistry(bytes32(0), registryVault);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        factory.setFeeTracker(YieldSeekerFeeTracker(address(0)));
    }

    function test_DuplicateOwnerIndexReverts() public {
        address walletOwner = makeAddr("wallet-owner");
        FeePlan[] memory noFeePlans = new FeePlan[](0);
        vm.prank(OPERATOR);
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), VAULT_AGENT_PROFILE, noFeePlans);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AgentAlreadyExists.selector, walletOwner, 8));
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), BORROW_AGENT_PROFILE, noFeePlans);
    }

    function test_ImplementationBoundToAnotherFactoryIsRejected() public {
        YieldSeekerAgentWalletFactory otherFactory = new YieldSeekerAgentWalletFactory(address(this), STRANGER);
        YieldSeekerAgentWalletV3 foreignImplementation = new YieldSeekerAgentWalletV3(address(otherFactory));

        vm.expectRevert(InvalidImplementationFactory.selector);
        factory.setAgentWalletImplementation(foreignImplementation);
    }
}
