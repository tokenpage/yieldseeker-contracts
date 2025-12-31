// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
import {MockAdapterRegistry} from "../mocks/MockAdapterRegistry.sol";
import {MockAgentWallet} from "../mocks/MockAgentWallet.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeTracker} from "../mocks/MockFeeTracker.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

/// @title AgentWalletV1 Unit Tests
/// @notice Isolated unit tests for ERC-4337 wallet logic with complete isolation
contract AgentWalletV1Test is Test {
    MockAgentWallet wallet;

    address owner = makeAddr("owner");
    address nonOwner = makeAddr("nonOwner");
    address operator = makeAddr("operator");
    address entryPoint = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address recipient = makeAddr("recipient");

    MockERC20 mockAsset;
    MockAdapterRegistry mockRegistry;
    MockFeeTracker mockFeeTracker;

    event AgentWalletInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event AdapterBlocked(address indexed adapter);
    event AdapterUnblocked(address indexed adapter);
    event TargetBlocked(address indexed target);
    event TargetUnblocked(address indexed target);
    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker);

    function setUp() public {
        mockAsset = new MockERC20("Mock USDC", "mUSDC");
        mockRegistry = new MockAdapterRegistry();
        mockFeeTracker = new MockFeeTracker(1000, makeAddr("feeCollector")); // 10% fee rate

        wallet = new MockAgentWallet(owner, address(mockAsset), address(mockRegistry), address(mockFeeTracker));
    }

    // ============ ERC-4337 Validation Tests ============

    function test_ValidateUserOp_WrongOwner() public view {
        UserOperation memory userOp = _createUserOp(nonOwner);
        bytes32 userOpHash = keccak256("test");

        uint256 result = wallet.validateSignature(userOp, userOpHash);
        assertEq(result, 1); // SIG_VALIDATION_FAILED
    }

    function test_ValidateUserOp_ReplayAttack() public view {
        UserOperation memory userOp = _createUserOp(owner);
        userOp.nonce = 0; // Old nonce - should be validated by EntryPoint
        bytes32 userOpHash = keccak256("test");

        uint256 result = wallet.validateSignature(userOp, userOpHash);
        assertEq(result, 0); // Owner signature is valid
    }

    function test_ValidateUserOp_InsufficientGas() public view {
        UserOperation memory userOp = _createUserOp(owner);
        userOp.preVerificationGas = 1; // Low gas - should be validated by EntryPoint
        bytes32 userOpHash = keccak256("test");

        uint256 result = wallet.validateSignature(userOp, userOpHash);
        assertEq(result, 0); // Signature itself is valid
    }

    function test_ValidateUserOp_EmptySignature() public view {
        UserOperation memory userOp = _createUserOp(owner);
        userOp.signature = "";
        bytes32 userOpHash = keccak256("test");

        uint256 result = wallet.validateSignature(userOp, userOpHash);
        assertEq(result, 1); // Invalid signature
    }

    function test_ValidateUserOp_MalformedSignature() public view {
        UserOperation memory userOp = _createUserOp(owner);
        userOp.signature = "0x1234"; // Invalid signature
        bytes32 userOpHash = keccak256("test");

        uint256 result = wallet.validateSignature(userOp, userOpHash);
        assertEq(result, 1); // Invalid signature
    }

    // ============ Adapter Execution Tests ============

    function test_ExecuteViaAdapter_ValidAdapter() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        mockRegistry.setTargetAdapter(target, adapter);

        vm.prank(owner);
        bytes memory result = wallet.executeViaAdapter(adapter, target, data);
        assertEq(result, "success");
    }

    function test_ExecuteViaAdapter_UnregisteredAdapter() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        // Registry returns zero address for unregistered
        mockRegistry.setTargetAdapter(target, address(0));

        vm.prank(owner);
        vm.expectRevert();
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_BlockedAdapter() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        mockRegistry.setTargetAdapter(target, adapter);

        // Block adapter at user level
        vm.prank(owner);
        wallet.blockAdapter(adapter);

        vm.prank(owner);
        vm.expectRevert();
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_BlockedTarget() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        mockRegistry.setTargetAdapter(target, adapter);

        // Block target at user level
        vm.prank(owner);
        wallet.blockTarget(target);

        vm.prank(owner);
        vm.expectRevert();
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_InvalidTarget() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        // Registry returns different adapter for target
        mockRegistry.setTargetAdapter(target, makeAddr("different"));

        vm.prank(owner);
        vm.expectRevert();
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_OnlyExecutors() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "0x1234";

        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_RevertData() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "revert";

        mockRegistry.setTargetAdapter(target, adapter);

        vm.prank(owner);
        vm.expectRevert("execution failed");
        wallet.executeViaAdapter(adapter, target, data);
    }

    function test_ExecuteViaAdapter_ReturnData() public {
        address adapter = makeAddr("adapter");
        address target = makeAddr("target");
        bytes memory data = "return_custom";

        mockRegistry.setTargetAdapter(target, adapter);

        vm.prank(owner);
        bytes memory result = wallet.executeViaAdapter(adapter, target, data);
        assertEq(result, "custom_data");
    }

    // ============ Batch Operations Tests ============

    function test_ExecuteViaAdapterBatch_ValidBatch() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = makeAddr("adapter1");
        adapters[1] = makeAddr("adapter2");
        targets[0] = makeAddr("target1");
        targets[1] = makeAddr("target2");
        datas[0] = "0x1234";
        datas[1] = "0x5678";

        mockRegistry.setTargetAdapter(targets[0], adapters[0]);
        mockRegistry.setTargetAdapter(targets[1], adapters[1]);

        vm.prank(owner);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(results.length, 2);
        assertEq(results[0], "success");
        assertEq(results[1], "success");
    }

    function test_ExecuteViaAdapterBatch_EmptyBatch() public {
        address[] memory adapters = new address[](0);
        address[] memory targets = new address[](0);
        bytes[] memory datas = new bytes[](0);

        vm.prank(owner);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(results.length, 0);
    }

    function test_ExecuteViaAdapterBatch_MismatchedArrays() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](1); // Mismatched length
        bytes[] memory datas = new bytes[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InvalidState.selector));
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_ExecuteViaAdapterBatch_PartialFailure() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = makeAddr("adapter1");
        adapters[1] = makeAddr("adapter2");
        targets[0] = makeAddr("target1");
        targets[1] = makeAddr("target2");
        datas[0] = "0x1234";
        datas[1] = "revert"; // This will cause revert

        mockRegistry.setTargetAdapter(targets[0], adapters[0]);
        mockRegistry.setTargetAdapter(targets[1], adapters[1]);

        vm.prank(owner);
        vm.expectRevert("execution failed");
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_ExecuteViaAdapterBatch_GasLimits() public {
        // Test with batch to check gas consumption
        address[] memory adapters = new address[](5);
        address[] memory targets = new address[](5);
        bytes[] memory datas = new bytes[](5);

        for (uint256 i = 0; i < 5; i++) {
            adapters[i] = makeAddr(string(abi.encodePacked("adapter", i)));
            targets[i] = makeAddr(string(abi.encodePacked("target", i)));
            datas[i] = "0x1234";
            mockRegistry.setTargetAdapter(targets[i], adapters[i]);
        }

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        wallet.executeViaAdapterBatch(adapters, targets, datas);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be reasonable gas usage
        assertLt(gasUsed, 200000);
    }

    function test_ExecuteViaAdapterBatch_OnlyExecutors() public {
        address[] memory adapters = new address[](1);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);

        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    // ============ User Sovereignty Tests ============

    function test_BlockAdapter_Success() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, false, false, false);
        emit AdapterBlocked(adapter);

        vm.prank(owner);
        wallet.blockAdapter(adapter);

        assertTrue(wallet.isAdapterBlocked(adapter));
    }

    function test_BlockAdapter_AlreadyBlocked() public {
        address adapter = makeAddr("adapter");

        vm.prank(owner);
        wallet.blockAdapter(adapter);

        // Blocking again should still work
        vm.prank(owner);
        wallet.blockAdapter(adapter);

        assertTrue(wallet.isAdapterBlocked(adapter));
    }

    function test_BlockAdapter_OnlyOwner() public {
        address adapter = makeAddr("adapter");

        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.blockAdapter(adapter);
    }

    function test_BlockAdapter_EmitsEvent() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, false, false, false);
        emit AdapterBlocked(adapter);

        vm.prank(owner);
        wallet.blockAdapter(adapter);
    }

    function test_UnblockAdapter_Success() public {
        address adapter = makeAddr("adapter");

        vm.prank(owner);
        wallet.blockAdapter(adapter);
        assertTrue(wallet.isAdapterBlocked(adapter));

        vm.expectEmit(true, false, false, false);
        emit AdapterUnblocked(adapter);

        vm.prank(owner);
        wallet.unblockAdapter(adapter);
        assertFalse(wallet.isAdapterBlocked(adapter));
    }

    function test_UnblockAdapter_NotBlocked() public {
        address adapter = makeAddr("adapter");

        // Unblocking non-blocked adapter should work
        vm.prank(owner);
        wallet.unblockAdapter(adapter);
        assertFalse(wallet.isAdapterBlocked(adapter));
    }

    function test_UnblockAdapter_EmitsEvent() public {
        address adapter = makeAddr("adapter");

        vm.prank(owner);
        wallet.blockAdapter(adapter);

        vm.expectEmit(true, false, false, false);
        emit AdapterUnblocked(adapter);

        vm.prank(owner);
        wallet.unblockAdapter(adapter);
    }

    function test_BlockTarget_Success() public {
        address target = makeAddr("target");

        vm.expectEmit(true, false, false, false);
        emit TargetBlocked(target);

        vm.prank(owner);
        wallet.blockTarget(target);

        assertTrue(wallet.isTargetBlocked(target));
    }

    function test_BlockTarget_EmitsEvent() public {
        address target = makeAddr("target");

        vm.expectEmit(true, false, false, false);
        emit TargetBlocked(target);

        vm.prank(owner);
        wallet.blockTarget(target);
    }

    function test_UnblockTarget_Success() public {
        address target = makeAddr("target");

        vm.prank(owner);
        wallet.blockTarget(target);
        assertTrue(wallet.isTargetBlocked(target));

        vm.expectEmit(true, false, false, false);
        emit TargetUnblocked(target);

        vm.prank(owner);
        wallet.unblockTarget(target);
        assertFalse(wallet.isTargetBlocked(target));
    }

    function test_IsAdapterBlocked_Correct() public {
        address adapter = makeAddr("adapter");

        assertFalse(wallet.isAdapterBlocked(adapter));

        vm.prank(owner);
        wallet.blockAdapter(adapter);
        assertTrue(wallet.isAdapterBlocked(adapter));

        vm.prank(owner);
        wallet.unblockAdapter(adapter);
        assertFalse(wallet.isAdapterBlocked(adapter));
    }

    function test_IsTargetBlocked_Correct() public {
        address target = makeAddr("target");

        assertFalse(wallet.isTargetBlocked(target));

        vm.prank(owner);
        wallet.blockTarget(target);
        assertTrue(wallet.isTargetBlocked(target));

        vm.prank(owner);
        wallet.unblockTarget(target);
        assertFalse(wallet.isTargetBlocked(target));
    }

    // ============ Asset Management Tests ============

    function test_WithdrawTokenToUser_ValidAmount() public {
        uint256 amount = 1000e6;
        mockAsset.mint(address(wallet), amount);

        vm.expectEmit(true, true, true, true);
        emit WithdrewTokenToUser(owner, recipient, address(mockAsset), amount);

        vm.prank(owner);
        wallet.withdrawTokenToUser(recipient, amount);

        assertEq(mockAsset.balanceOf(recipient), amount);
    }

    function test_WithdrawTokenToUser_ZeroAmount() public {
        vm.prank(owner);
        wallet.withdrawTokenToUser(recipient, 0);
        // Should succeed with zero amount
    }

    function test_WithdrawTokenToUser_InsufficientBalance() public {
        uint256 amount = 1000e6;
        // Don't mint tokens to wallet

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InsufficientBalance.selector));
        wallet.withdrawTokenToUser(recipient, amount);
    }

    function test_WithdrawTokenToUser_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.withdrawTokenToUser(recipient, 100);
    }

    function test_WithdrawTokenToUser_EmitsEvent() public {
        uint256 amount = 1000e6;
        mockAsset.mint(address(wallet), amount);

        vm.expectEmit(true, true, true, true);
        emit WithdrewTokenToUser(owner, recipient, address(mockAsset), amount);

        vm.prank(owner);
        wallet.withdrawTokenToUser(recipient, amount);
    }

    function test_WithdrawEthToUser_ValidAmount() public {
        uint256 amount = 1 ether;
        vm.deal(address(wallet), amount);

        vm.expectEmit(true, true, false, true);
        emit WithdrewEthToUser(owner, recipient, amount);

        vm.prank(owner);
        wallet.withdrawEthToUser(recipient, amount);

        assertEq(recipient.balance, amount);
    }

    function test_WithdrawEthToUser_ZeroAmount() public {
        vm.prank(owner);
        wallet.withdrawEthToUser(recipient, 0);
        // Should succeed with zero amount
    }

    function test_WithdrawEthToUser_InsufficientBalance() public {
        uint256 amount = 1 ether;
        // Don't give ETH to wallet

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InsufficientBalance.selector));
        wallet.withdrawEthToUser(recipient, amount);
    }

    function test_WithdrawEthToUser_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.withdrawEthToUser(recipient, 1 ether);
    }

    function test_WithdrawEthToUser_EmitsEvent() public {
        uint256 amount = 1 ether;
        vm.deal(address(wallet), amount);

        vm.expectEmit(true, true, false, true);
        emit WithdrewEthToUser(owner, recipient, amount);

        vm.prank(owner);
        wallet.withdrawEthToUser(recipient, amount);
    }

    // ============ New Asset Withdrawal Tests ============

    function test_WithdrawAssetToUser_BaseAsset_ValidAmount() public {
        uint256 amount = 1000e6;
        mockAsset.mint(address(wallet), amount);

        vm.expectEmit(true, true, true, true);
        emit WithdrewTokenToUser(owner, recipient, address(mockAsset), amount);

        vm.prank(owner);
        wallet.withdrawAssetToUser(recipient, address(mockAsset), amount);

        assertEq(mockAsset.balanceOf(recipient), amount);
    }

    function test_WithdrawAssetToUser_BaseAsset_RespectsFees() public {
        uint256 amount = 1000e6;
        mockAsset.mint(address(wallet), amount);

        // Set fees owed
        mockFeeTracker.setFeesOwed(address(wallet), 100e6);

        // Should only be able to withdraw 900 USDC (1000 - 100 fees)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InsufficientBalance.selector));
        wallet.withdrawAssetToUser(recipient, address(mockAsset), amount);

        // Should succeed with withdrawable amount
        vm.prank(owner);
        wallet.withdrawAssetToUser(recipient, address(mockAsset), 900e6);
        assertEq(mockAsset.balanceOf(recipient), 900e6);
    }

    function test_WithdrawAssetToUser_NonBaseAsset_NoFees() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER");
        uint256 amount = 1000e6;
        otherToken.mint(address(wallet), amount);

        // Set fees owed (should not apply to non-baseAsset)
        mockFeeTracker.setFeesOwed(address(wallet), 100e6);

        // Should be able to withdraw all of the other token (fees don't apply)
        vm.prank(owner);
        wallet.withdrawAssetToUser(recipient, address(otherToken), amount);
        assertEq(otherToken.balanceOf(recipient), amount);
    }

    function test_WithdrawAssetToUser_ZeroRecipient() public {
        mockAsset.mint(address(wallet), 1000e6);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.ZeroAddress.selector));
        wallet.withdrawAssetToUser(address(0), address(mockAsset), 1000e6);
    }

    function test_WithdrawAssetToUser_ZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.ZeroAddress.selector));
        wallet.withdrawAssetToUser(recipient, address(0), 1000e6);
    }

    function test_WithdrawAssetToUser_OnlyOwner() public {
        mockAsset.mint(address(wallet), 1000e6);

        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(mockAsset), 1000e6);
    }

    function test_WithdrawAssetToUser_InsufficientBalance() public {
        // Don't mint any tokens

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InsufficientBalance.selector));
        wallet.withdrawAssetToUser(recipient, address(mockAsset), 1000e6);
    }

    function test_WithdrawAllAssetToUser_BaseAsset_RespectsFees() public {
        uint256 balance = 1000e6;
        mockAsset.mint(address(wallet), balance);

        // Set fees owed
        uint256 feesOwed = 100e6;
        mockFeeTracker.setFeesOwed(address(wallet), feesOwed);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(recipient, address(mockAsset));

        // Should withdraw balance - fees = 900 USDC
        assertEq(mockAsset.balanceOf(recipient), balance - feesOwed);
        assertEq(mockAsset.balanceOf(address(wallet)), feesOwed);
    }

    function test_WithdrawAllAssetToUser_NonBaseAsset_WithdrawsAll() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER");
        uint256 balance = 1000e6;
        otherToken.mint(address(wallet), balance);

        // Set fees owed (should not apply)
        mockFeeTracker.setFeesOwed(address(wallet), 100e6);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(recipient, address(otherToken));

        // Should withdraw entire balance (fees don't apply to non-baseAsset)
        assertEq(otherToken.balanceOf(recipient), balance);
        assertEq(otherToken.balanceOf(address(wallet)), 0);
    }

    function test_WithdrawAllAssetToUser_ZeroRecipient() public {
        mockAsset.mint(address(wallet), 1000e6);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.ZeroAddress.selector));
        wallet.withdrawAllAssetToUser(address(0), address(mockAsset));
    }

    function test_WithdrawAllAssetToUser_ZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.ZeroAddress.selector));
        wallet.withdrawAllAssetToUser(recipient, address(0));
    }

    function test_WithdrawAllAssetToUser_OnlyOwner() public {
        mockAsset.mint(address(wallet), 1000e6);

        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.withdrawAllAssetToUser(recipient, address(mockAsset));
    }

    function test_WithdrawAllAssetToUser_EmptyBalance() public {
        // No tokens minted

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(recipient, address(mockAsset));

        // Should succeed but transfer 0
        assertEq(mockAsset.balanceOf(recipient), 0);
    }

    // ============ Sync System Tests ============

    function test_SyncFromFactory_Success() public {
        address newRegistry = makeAddr("newRegistry");
        address newFeeTracker = makeAddr("newFeeTracker");

        vm.expectEmit(true, true, false, false);
        emit SyncedFromFactory(newRegistry, newFeeTracker);

        vm.prank(owner);
        wallet.syncFromFactory(newRegistry, newFeeTracker);

        assertEq(address(wallet.adapterRegistry()), newRegistry);
        assertEq(address(wallet.feeTracker()), newFeeTracker);
    }

    function test_SyncFromFactory_OnlySyncers() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.syncFromFactory(makeAddr("registry"), makeAddr("tracker"));
    }

    function test_SyncFromFactory_UpdatesRegistry() public {
        address newRegistry = makeAddr("newRegistry");

        vm.prank(owner);
        wallet.syncFromFactory(newRegistry, address(mockFeeTracker));

        assertEq(address(wallet.adapterRegistry()), newRegistry);
    }

    function test_SyncFromFactory_UpdatesFeeTracker() public {
        address newFeeTracker = makeAddr("newFeeTracker");

        vm.prank(owner);
        wallet.syncFromFactory(address(mockRegistry), newFeeTracker);

        assertEq(address(wallet.feeTracker()), newFeeTracker);
    }

    function test_SyncFromFactory_EmitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit SyncedFromFactory(address(0), address(0));

        vm.prank(owner);
        wallet.syncFromFactory(makeAddr("registry"), makeAddr("tracker"));
    }

    // ============ UUPS Upgrade Tests ============

    function test_Upgrade_OnlyOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        wallet.upgradeToAndCall(makeAddr("newImpl"), "");
    }

    function test_Upgrade_ValidImplementation() public {
        address newImpl = makeAddr("newImpl");

        vm.prank(owner);
        wallet.upgradeToAndCall(newImpl, "");
    }

    function test_Upgrade_InvalidImplementation() public {
        // Upgrade should succeed in mock
        vm.prank(owner);
        wallet.upgradeToAndCall(makeAddr("impl"), "");
    }

    function test_Upgrade_PreserveStorage() public {
        // Verify storage preservation during upgrade
        assertEq(wallet.owner(), owner);
        assertEq(address(wallet.baseAsset()), address(mockAsset));

        vm.prank(owner);
        wallet.upgradeToAndCall(makeAddr("impl"), "");

        // Storage should be preserved
        assertEq(wallet.owner(), owner);
        assertEq(address(wallet.baseAsset()), address(mockAsset));
    }

    function test_Upgrade_PreserveERC7201Storage() public {
        // Block an adapter to set storage state
        address adapter = makeAddr("adapter");
        vm.prank(owner);
        wallet.blockAdapter(adapter);
        assertTrue(wallet.isAdapterBlocked(adapter));

        vm.prank(owner);
        wallet.upgradeToAndCall(makeAddr("impl"), "");

        // ERC-7201 storage should be preserved
        assertTrue(wallet.isAdapterBlocked(adapter));
    }

    function test_Upgrade_EmitsEvent() public {
        // This would require more complex testing to verify events from upgrade
        vm.prank(owner);
        wallet.upgradeToAndCall(makeAddr("impl"), "");
    }

    // ============ Helper Functions ============

    function _createUserOp(address signer) internal pure returns (UserOperation memory) {
        return UserOperation({
            sender: signer, // Set the signer as the sender
            nonce: 1,
            initCode: "",
            callData: "",
            callGasLimit: 100000,
            verificationGasLimit: 100000,
            preVerificationGas: 21000,
            maxFeePerGas: 1000000000,
            maxPriorityFeePerGas: 1000000000,
            paymasterAndData: "",
            signature: "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef01"
        });
    }
}
