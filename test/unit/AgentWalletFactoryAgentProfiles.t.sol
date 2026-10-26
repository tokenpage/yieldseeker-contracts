// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {AgentAlreadyExists, InvalidImplementationFactory, UnknownAgentProfile} from "../../src/agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
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
    YieldSeekerBorrowFeeModule private feeBorrow;
    YieldSeekerAgentWalletFactory private factory;

    function setUp() public {
        baseAsset = new MockERC20("Base Asset", "BASE");
        registryVault = new YieldSeekerAdapterRegistry(address(this), address(this));
        registryBorrow = new YieldSeekerAdapterRegistry(address(this), address(this));
        feeVault = new YieldSeekerFeeTracker(address(this), address(this), FEE_COLLECTOR_A);
        feeBorrow = new YieldSeekerBorrowFeeModule(feeVault, new MockSwapAdapterPriceOracle(), 500);
        feeVault.setFeeModule(BORROW_FEE, feeBorrow);
        feeVault.setPlanRate(0, BORROW_FEE, 500);
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

        vm.startPrank(OPERATOR);
        YieldSeekerAgentWalletV3 vaultWallet = factory.createAgentWallet(walletOwner, vaultIndex, address(baseAsset), VAULT_AGENT_PROFILE);
        YieldSeekerAgentWalletV3 borrowWallet = factory.createAgentWallet(walletOwner, borrowIndex, address(baseAsset), BORROW_AGENT_PROFILE);
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

    function test_CreateAgentWalletRequiresOperatorRole() public {
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, operatorRole));
        factory.createAgentWallet(makeAddr("wallet-owner"), 1, address(baseAsset), VAULT_AGENT_PROFILE);
    }

    function test_CreateAgentWalletRejectsUnknownAgentProfile() public {
        bytes32 unknown = keccak256("missing-agent-profile");
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, unknown));
        factory.createAgentWallet(makeAddr("wallet-owner"), 1, address(baseAsset), unknown);
    }

    function test_AgentProfileZeroAndZeroFeeTrackerAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(0)));
        factory.setAdapterRegistry(bytes32(0), registryVault);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        factory.setFeeTracker(YieldSeekerFeeTracker(address(0)));
    }

    function test_DuplicateOwnerIndexReverts() public {
        address walletOwner = makeAddr("wallet-owner");
        vm.prank(OPERATOR);
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), VAULT_AGENT_PROFILE);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(AgentAlreadyExists.selector, walletOwner, 8));
        factory.createAgentWallet(walletOwner, 8, address(baseAsset), BORROW_AGENT_PROFILE);
    }

    function test_ImplementationBoundToAnotherFactoryIsRejected() public {
        YieldSeekerAgentWalletFactory otherFactory = new YieldSeekerAgentWalletFactory(address(this), STRANGER);
        YieldSeekerAgentWalletV3 foreignImplementation = new YieldSeekerAgentWalletV3(address(otherFactory));

        vm.expectRevert(InvalidImplementationFactory.selector);
        factory.setAgentWalletImplementation(foreignImplementation);
    }
}
