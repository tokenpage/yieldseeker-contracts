// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactoryV2} from "../../src/AgentWalletFactoryV2.sol";
import {InvalidAsset} from "../../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {NotApprovedImplementation} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3YieldSeekerWalletV1, MockV3YieldSeekerWalletV2} from "../mocks/MockV3TestHelpers.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

contract AgentWalletV3Test is Test {
    using MessageHashUtils for bytes32;

    bytes32 private constant VAULT_PROFILE = keccak256("vault-profile");
    bytes32 private constant BORROW_PROFILE = keccak256("borrow-profile");
    address private constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private admin;
    address private owner;
    uint256 private ownerKey;
    address private operator;
    uint256 private operatorKey;
    address private recipient = makeAddr("recipient");
    address private feeCollector = makeAddr("fee-collector");

    MockERC20 private usdc;
    MockERC20 private weth;
    MockERC20 private unrelated;
    YieldSeekerAdapterRegistry private vaultRegistry;
    YieldSeekerAdapterRegistry private borrowRegistry;
    YieldSeekerVaultFeeModule private vaultFees;
    YieldSeekerBorrowFeeModule private borrowFees;
    YieldSeekerAgentWalletFactoryV2 private factory;
    YieldSeekerAgentWalletV3 private vaultWallet;
    YieldSeekerAgentWalletV3 private borrowWallet;

    function setUp() public {
        admin = address(this);
        (owner, ownerKey) = makeAddrAndKey("owner");
        (operator, operatorKey) = makeAddrAndKey("operator");
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");
        unrelated = new MockERC20("Unrelated", "NOPE");
        vaultRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        borrowRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        vaultFees = new YieldSeekerVaultFeeModule(admin, admin, feeCollector, 10_000, 1_000);
        borrowFees = new YieldSeekerBorrowFeeModule(admin, admin, feeCollector, 10_000, 1_000);
        factory = new YieldSeekerAgentWalletFactoryV2(admin, operator);

        MockV3YieldSeekerWalletV1 implementation = new MockV3YieldSeekerWalletV1(address(factory));
        factory.setAgentWalletImplementation(implementation);
        factory.setProfileAdapterRegistry(VAULT_PROFILE, vaultRegistry);
        factory.setProfileAdapterRegistry(BORROW_PROFILE, borrowRegistry);
        factory.setProfileFeeTracker(VAULT_PROFILE, YieldSeekerFeeTracker(address(vaultFees)));
        factory.setProfileFeeTracker(BORROW_PROFILE, YieldSeekerFeeTracker(address(borrowFees)));

        vm.startPrank(operator);
        vaultWallet = factory.createAgentWallet(owner, 1, address(usdc), VAULT_PROFILE);
        borrowWallet = factory.createAgentWallet(owner, 2, address(weth), BORROW_PROFILE);
        vm.stopPrank();

        usdc.mint(address(vaultWallet), 1_000e6);
        usdc.mint(address(borrowWallet), 1_000e6);
        weth.mint(address(borrowWallet), 400e6);
    }

    function test_ProfileFeeTrackerIsPinnedWhileRegistryAndOperatorsResync() public {
        YieldSeekerAdapterRegistry nextRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        YieldSeekerVaultFeeModule nextFees = new YieldSeekerVaultFeeModule(admin, admin, feeCollector, 10_000, 250);
        address nextOperator = makeAddr("next-operator");
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();

        factory.setProfileAdapterRegistry(VAULT_PROFILE, nextRegistry);
        factory.setProfileFeeTracker(VAULT_PROFILE, YieldSeekerFeeTracker(address(nextFees)));
        factory.grantRole(operatorRole, nextOperator);
        factory.revokeRole(operatorRole, operator);

        vm.prank(owner);
        vaultWallet.syncFromFactory();

        assertEq(address(vaultWallet.feeTracker()), address(vaultFees));
        assertEq(address(vaultWallet.adapterRegistry()), address(nextRegistry));
        assertFalse(vaultWallet.isAgentOperator(operator));
        assertTrue(vaultWallet.isAgentOperator(nextOperator));
        address[] memory syncedOperators = vaultWallet.listAgentOperators();
        assertEq(syncedOperators.length, 1);
        assertEq(syncedOperators[0], nextOperator);
    }

    function test_UpgradeToLatestUsesOnlyTheFactoryApprovedImplementation() public {
        MockV3YieldSeekerWalletV2 nextImplementation = new MockV3YieldSeekerWalletV2(address(factory));
        MockV3YieldSeekerWalletV2 unapprovedImplementation = new MockV3YieldSeekerWalletV2(address(factory));
        factory.setAgentWalletImplementation(nextImplementation);

        vm.prank(owner);
        vm.expectRevert(NotApprovedImplementation.selector);
        vaultWallet.upgradeToAndCall(address(unapprovedImplementation), "");

        vm.prank(owner);
        vaultWallet.upgradeToLatest();

        assertEq(address(uint160(uint256(vm.load(address(vaultWallet), IMPLEMENTATION_SLOT)))), address(nextImplementation));
        assertEq(MockV3YieldSeekerWalletV2(payable(address(vaultWallet))).version(), 2);
        assertEq(vaultWallet.owner(), owner);
        assertEq(address(vaultWallet.feeTracker()), address(vaultFees));
    }

    function test_OperatorSignatureOnlyAuthorizesAdapterExecution() public {
        bytes memory executeCall = abi.encodeWithSelector(vaultWallet.executeViaAdapter.selector, address(0xA11CE), address(usdc), hex"1234");
        bytes memory withdrawCall = abi.encodeWithSelector(vaultWallet.withdrawAssetToUser.selector, recipient, address(usdc), 1);

        assertEq(_validateWithSigner(executeCall, operatorKey), 0);
        assertEq(_validateWithSigner(withdrawCall, operatorKey), 1);
    }

    function test_VaultFeeModuleReservesBaseFeesAndRejectsNonBaseWithdrawal() public {
        vm.prank(address(vaultWallet));
        vaultFees.recordAgentYieldEarned(100e6);
        assertEq(vaultFees.getFeesOwed(address(vaultWallet)), 10e6);

        vm.prank(owner);
        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), 990e6 + 1);

        vm.prank(owner);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), 990e6);
        assertEq(usdc.balanceOf(recipient), 990e6);
        assertEq(usdc.balanceOf(address(vaultWallet)), 10e6);

        unrelated.mint(address(vaultWallet), 3e6);
        vm.prank(owner);
        vm.expectRevert(InvalidAsset.selector);
        vaultWallet.withdrawAssetToUser(recipient, address(unrelated), 1e6);
    }

    function test_VaultWithdrawAllLeavesFeesOwedInWallet() public {
        vm.prank(address(vaultWallet));
        vaultFees.recordAgentYieldEarned(100e6);

        vm.prank(owner);
        vaultWallet.withdrawAllAssetToUser(recipient, address(usdc));

        assertEq(usdc.balanceOf(recipient), 990e6);
        assertEq(usdc.balanceOf(address(vaultWallet)), 10e6);
        assertEq(vaultFees.getFeesOwed(address(vaultWallet)), 10e6);
    }

    function test_CollectFeesPaysVaultModuleCollectorAndClearsOwedAmount() public {
        vm.prank(address(vaultWallet));
        vaultFees.recordAgentYieldEarned(100e6);

        vm.prank(operator);
        vaultWallet.collectFees();

        assertEq(usdc.balanceOf(feeCollector), 10e6);
        assertEq(usdc.balanceOf(address(vaultWallet)), 990e6);
        assertEq(vaultFees.getFeesOwed(address(vaultWallet)), 0);
    }

    function test_BorrowFeeModuleReservesBorrowedTokenFeesButAllowsCollateral() public {
        bytes32 market = keccak256("test-market");
        uint256 startTime = vm.getBlockTimestamp();
        if (startTime == 0) {
            vm.warp(1);
        }
        vm.prank(address(borrowWallet));
        borrowFees.recordBorrow(market, address(usdc), 100e6, 0);

        uint256 reportTime = vm.getBlockTimestamp();
        vm.warp(reportTime + 365 days);
        vm.prank(address(borrowWallet));
        borrowFees.checkpoint(market, address(usdc), 100e6);
        assertEq(borrowFees.feesOwed(address(borrowWallet), address(usdc)), 10e6);

        vm.prank(owner);
        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        borrowWallet.withdrawAssetToUser(recipient, address(usdc), 990e6 + 1);

        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(usdc), 990e6);
        assertEq(usdc.balanceOf(recipient), 990e6);
        assertEq(usdc.balanceOf(address(borrowWallet)), 10e6);

        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(weth), 400e6);
        assertEq(weth.balanceOf(recipient), 400e6);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);

        unrelated.mint(address(borrowWallet), 3e6);
        vm.prank(owner);
        vm.expectRevert(InvalidAsset.selector);
        borrowWallet.withdrawAssetToUser(recipient, address(unrelated), 1e6);
    }

    function _validateWithSigner(bytes memory callData, uint256 signerKey) private returns (uint256) {
        bytes32 userOpHash = keccak256(abi.encode(callData, vm.getBlockTimestamp()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        UserOperation memory userOp = UserOperation({
            sender: address(vaultWallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 21_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: abi.encodePacked(r, s, v)
        });

        vm.prank(ENTRY_POINT);
        return vaultWallet.validateUserOp(userOp, userOpHash, 0);
    }
}
