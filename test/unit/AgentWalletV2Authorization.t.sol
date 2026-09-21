// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {InvalidAsset} from "../../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletV2 as AgentWalletV2} from "../../src/AgentWalletV2.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {AWKAgentWalletV1, InvalidState} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

/// @title Agent Wallet V2 Authorization Unit Tests
/// @notice Exercises the real AWKAgentWalletV2/YieldSeekerAgentWalletV2 onlyOwner /
///         _validateSignature logic: every owner action is EntryPoint-relayable with the owner's
///         signature, while operator signatures remain limited to the adapter-execution selectors.
///         V1 is deployed unmodified alongside V2 in every test to prove the factory can serve
///         both simultaneously.
contract AgentWalletV2AuthorizationTest is Test {
    using MessageHashUtils for bytes32;

    address internal constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event AdapterBlocked(address indexed adapter);
    event AdapterUnblocked(address indexed adapter);
    event TargetBlocked(address indexed target);
    event TargetUnblocked(address indexed target);

    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    MockERC20 usdc;
    MockERC4626 vault;
    AgentWalletV2 wallet;

    address admin = makeAddr("admin");
    address ownerAddr;
    uint256 ownerKey;
    address operatorAddr;
    uint256 operatorKey;
    address strangerAddr;
    uint256 strangerKey;
    address recipient = makeAddr("recipient");

    function setUp() public {
        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
        (operatorAddr, operatorKey) = makeAddrAndKey("operator");
        (strangerAddr, strangerKey) = makeAddrAndKey("stranger");

        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(0, admin);
        factory = new AgentWalletFactory(admin, operatorAddr);
        AgentWalletV2 implementation = new AgentWalletV2(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(AWKAgentWalletV1(payable(address(implementation))));
        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();

        vm.prank(operatorAddr);
        wallet = AgentWalletV2(payable(address(factory.createAgentWallet(ownerAddr, 1, address(usdc)))));

        usdc.mint(address(wallet), 1_000e6);
    }

    // ============ _validateSignature: withdrawal selectors are owner-only ============

    function test_ValidateUserOp_WithdrawSelector_OwnerSignature_Succeeds() public {
        uint256 result = _validateWithSigner(_withdrawCallData(), ownerKey);
        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_WithdrawSelector_OperatorSignature_Fails() public {
        uint256 result = _validateWithSigner(_withdrawCallData(), operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_WithdrawAllSelector_OperatorSignature_Fails() public {
        bytes memory callData = abi.encodeWithSelector(wallet.withdrawAllAssetToUser.selector, recipient, address(usdc));
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_WithdrawSelector_StrangerSignature_Fails() public {
        uint256 result = _validateWithSigner(_withdrawCallData(), strangerKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_EmptySignature_Reverts() public {
        bytes memory callData = _withdrawCallData();
        bytes32 userOpHash = keccak256(abi.encode(callData, block.timestamp));
        UserOperation memory userOp = _buildUserOp(callData, "");

        vm.prank(ENTRY_POINT);
        vm.expectRevert();
        wallet.validateUserOp(userOp, userOpHash, 0);
    }

    function test_ValidateUserOp_MalformedSignature_Reverts() public {
        bytes memory callData = _withdrawCallData();
        bytes32 userOpHash = keccak256(abi.encode(callData, block.timestamp));
        UserOperation memory userOp = _buildUserOp(callData, hex"1234");

        vm.prank(ENTRY_POINT);
        vm.expectRevert();
        wallet.validateUserOp(userOp, userOpHash, 0);
    }

    // ============ _validateSignature: every owner selector requires the owner ============

    function test_ValidateUserOp_OwnerSignature_SucceedsForEveryOwnerSelector() public {
        bytes[] memory ownerCalls = _ownerActionCallData();
        for (uint256 i; i < ownerCalls.length; ++i) {
            assertEq(_validateWithSigner(ownerCalls[i], ownerKey), SIG_VALIDATION_SUCCESS);
        }
    }

    function test_ValidateUserOp_OperatorSignature_FailsForEveryOwnerSelector() public {
        bytes[] memory ownerCalls = _ownerActionCallData();
        for (uint256 i; i < ownerCalls.length; ++i) {
            assertEq(_validateWithSigner(ownerCalls[i], operatorKey), SIG_VALIDATION_FAILED);
        }
    }

    // ============ _validateSignature: adapter-execution selectors are operator-authorizable ============

    function test_ValidateUserOp_ExecuteViaAdapterSelector_OperatorSignature_Succeeds() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory callData = abi.encodeWithSelector(wallet.executeViaAdapter.selector, address(vaultAdapter), address(vault), depositData);
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_ExecuteViaAdapterBatchSelector_OperatorSignature_Succeeds() public {
        address[] memory adapters = new address[](1);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);
        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory callData = abi.encodeWithSelector(wallet.executeViaAdapterBatch.selector, adapters, targets, datas);
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_SUCCESS);
    }

    function test_ValidateUserOp_ShortCallData_OperatorSignature_Fails() public {
        uint256 result = _validateWithSigner("", operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    // ============ EntryPoint gating on validateUserOp itself ============

    function test_ValidateUserOp_RevertsIfNotCalledByEntryPoint() public {
        UserOperation memory userOp = _buildUserOp(_withdrawCallData(), _sign(ownerKey, keccak256("op")));
        vm.expectRevert("account: not from EntryPoint");
        wallet.validateUserOp(userOp, keccak256("op"), 0);
    }

    // ============ onlyOwner: EntryPoint-relayed calls authorized like direct owner calls ============

    function test_EntryPoint_CanCallWithdrawAssetToUser() public {
        vm.prank(ENTRY_POINT);
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
        assertEq(usdc.balanceOf(recipient), 500e6);
    }

    function test_EntryPoint_CanCallWithdrawAllAssetToUser() public {
        vm.prank(ENTRY_POINT);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));
        assertEq(usdc.balanceOf(recipient), 1_000e6);
    }

    function test_EntryPoint_CanManageAdapterAndTargetBlocklists() public {
        address blockedAdapter = makeAddr("blockedAdapter");
        address blockedTarget = makeAddr("blockedTarget");

        vm.prank(ENTRY_POINT);
        wallet.blockAdapter(blockedAdapter);
        assertTrue(wallet.isAdapterBlocked(blockedAdapter));

        vm.prank(ENTRY_POINT);
        wallet.unblockAdapter(blockedAdapter);
        assertFalse(wallet.isAdapterBlocked(blockedAdapter));

        vm.prank(ENTRY_POINT);
        wallet.blockTarget(blockedTarget);
        assertTrue(wallet.isTargetBlocked(blockedTarget));

        vm.prank(ENTRY_POINT);
        wallet.unblockTarget(blockedTarget);
        assertFalse(wallet.isTargetBlocked(blockedTarget));
    }

    function test_EntryPoint_CanCallWithdrawEthVariants() public {
        uint256 recipientBalanceBefore = recipient.balance;
        vm.deal(address(wallet), 1 ether);

        vm.prank(ENTRY_POINT);
        wallet.withdrawEthToUser(recipient, 0.4 ether);
        assertEq(recipient.balance, recipientBalanceBefore + 0.4 ether);

        vm.prank(ENTRY_POINT);
        wallet.withdrawAllEthToUser(recipient);
        assertEq(recipient.balance, recipientBalanceBefore + 1 ether);
    }

    function test_EntryPoint_CanCallSyncFromFactory() public {
        vm.prank(ENTRY_POINT);
        wallet.syncFromFactory();
        assertEq(address(wallet.adapterRegistry()), address(registry));
    }

    function test_EntryPoint_CanCallUpgradeToLatest() public {
        AgentWalletV2 nextImplementation;

        vm.prank(admin);
        nextImplementation = new AgentWalletV2(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(AWKAgentWalletV1(payable(address(nextImplementation))));

        vm.prank(ENTRY_POINT);
        wallet.upgradeToLatest();

        assertEq(_implementation(), address(nextImplementation));
    }

    function test_EntryPoint_CanCallUpgradeToAndCall() public {
        AgentWalletV2 nextImplementation;

        vm.prank(admin);
        nextImplementation = new AgentWalletV2(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(AWKAgentWalletV1(payable(address(nextImplementation))));

        vm.prank(ENTRY_POINT);
        wallet.upgradeToAndCall(address(nextImplementation), "");

        assertEq(_implementation(), address(nextImplementation));
    }

    function test_EntryPoint_RespectsWithdrawableBalanceGate() public {
        // _getWithdrawableBalance still runs ahead of the transfer under the EntryPoint-relayed
        // path, not just the direct-call path.
        vm.prank(ENTRY_POINT);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector));
        wallet.withdrawAssetToUser(recipient, address(usdc), 10_000e6);
    }

    // ============ onlyOwner: non-owner, non-EntryPoint callers still rejected ============

    function test_Stranger_CannotCallWithdrawAssetToUser() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
    }

    function test_Operator_CannotCallWithdrawAssetToUser_Directly() public {
        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
    }

    // ============ onlyExecutors: operators keep direct adapter authority ============

    function test_Operator_CanCallExecuteViaAdapter_Directly() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        vm.prank(operatorAddr);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertGt(vault.balanceOf(address(wallet)), 0);
    }

    // ============ Adapter execution parity coverage ============

    function test_ExecuteViaAdapter_OwnerCanExecute_Directly() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(ownerAddr);
        bytes memory result = wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        (uint256 shares,) = abi.decode(result, (uint256, uint256));
        assertGt(shares, 0);
    }

    function test_ExecuteViaAdapter_UnregisteredAdapter_Reverts() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));
        address unregisteredAdapter = makeAddr("unregisteredAdapter");

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(unregisteredAdapter, address(vault), depositData);
    }

    function test_ExecuteViaAdapter_BlockedAdapter_Reverts() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(ownerAddr);
        wallet.blockAdapter(address(vaultAdapter));

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_ExecuteViaAdapter_BlockedTarget_Reverts() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(ownerAddr);
        wallet.blockTarget(address(vault));

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_ExecuteViaAdapter_InvalidTarget_Reverts() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), makeAddr("unregisteredTarget"), depositData);
    }

    function test_ExecuteViaAdapter_NonExecutor_Reverts() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_ExecuteViaAdapter_FailedAdapterCall_Reverts() public {
        bytes memory zeroDepositData = abi.encodeCall(vaultAdapter.deposit, (0));

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), zeroDepositData);
    }

    function test_ExecuteViaAdapterBatch_ValidBatch() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        adapters[0] = address(vaultAdapter);
        adapters[1] = address(vaultAdapter);
        targets[0] = address(vault);
        targets[1] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (100e6));
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(ownerAddr);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(results.length, 2);
        assertGt(vault.balanceOf(address(wallet)), 0);
    }

    function test_ExecuteViaAdapterBatch_EmptyBatch() public {
        vm.prank(ownerAddr);
        bytes[] memory results = wallet.executeViaAdapterBatch(new address[](0), new address[](0), new bytes[](0));

        assertEq(results.length, 0);
    }

    function test_ExecuteViaAdapterBatch_MismatchedArrays() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](2);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(InvalidState.selector));
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_ExecuteViaAdapterBatch_PartialFailure_RollsBack() public {
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        adapters[0] = address(vaultAdapter);
        adapters[1] = address(vaultAdapter);
        targets[0] = address(vault);
        targets[1] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (100e6));
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (0));

        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vault.balanceOf(address(wallet)), 0);
    }

    function test_ExecuteViaAdapterBatch_NonExecutor_Reverts() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(new address[](0), new address[](0), new bytes[](0));
    }

    // ============ User sovereignty parity coverage ============

    function test_BlockAdapter_Success() public {
        address adapter = makeAddr("adapter");

        vm.expectEmit(true, false, false, false);
        emit AdapterBlocked(adapter);

        vm.prank(ownerAddr);
        wallet.blockAdapter(adapter);

        assertTrue(wallet.isAdapterBlocked(adapter));
    }

    function test_BlockAdapter_AlreadyBlocked() public {
        address adapter = makeAddr("adapter");

        vm.prank(ownerAddr);
        wallet.blockAdapter(adapter);
        vm.prank(ownerAddr);
        wallet.blockAdapter(adapter);

        assertTrue(wallet.isAdapterBlocked(adapter));
    }

    function test_BlockAdapter_OnlyOwner() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.blockAdapter(makeAddr("adapter"));
    }

    function test_UnblockAdapter_Success() public {
        address adapter = makeAddr("adapter");

        vm.prank(ownerAddr);
        wallet.blockAdapter(adapter);
        vm.expectEmit(true, false, false, false);
        emit AdapterUnblocked(adapter);
        vm.prank(ownerAddr);
        wallet.unblockAdapter(adapter);

        assertFalse(wallet.isAdapterBlocked(adapter));
    }

    function test_UnblockAdapter_NotBlocked() public {
        address adapter = makeAddr("adapter");

        vm.prank(ownerAddr);
        wallet.unblockAdapter(adapter);

        assertFalse(wallet.isAdapterBlocked(adapter));
    }

    function test_BlockTarget_Success() public {
        address target = makeAddr("target");

        vm.expectEmit(true, false, false, false);
        emit TargetBlocked(target);
        vm.prank(ownerAddr);
        wallet.blockTarget(target);

        assertTrue(wallet.isTargetBlocked(target));
    }

    function test_UnblockTarget_Success() public {
        address target = makeAddr("target");

        vm.prank(ownerAddr);
        wallet.blockTarget(target);
        vm.expectEmit(true, false, false, false);
        emit TargetUnblocked(target);
        vm.prank(ownerAddr);
        wallet.unblockTarget(target);

        assertFalse(wallet.isTargetBlocked(target));
    }

    // ============ Withdrawal parity coverage ============

    function test_WithdrawAssetToUser_ValidAmount() public {
        uint256 amount = 500e6;

        vm.expectEmit(true, true, true, true);
        emit WithdrewTokenToUser(ownerAddr, recipient, address(usdc), amount);
        vm.prank(ownerAddr);
        wallet.withdrawAssetToUser(recipient, address(usdc), amount);

        assertEq(usdc.balanceOf(recipient), amount);
    }

    function test_WithdrawAssetToUser_ZeroAmount() public {
        vm.prank(ownerAddr);
        wallet.withdrawAssetToUser(recipient, address(usdc), 0);

        assertEq(usdc.balanceOf(recipient), 0);
    }

    function test_WithdrawAssetToUser_ZeroRecipient() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        wallet.withdrawAssetToUser(address(0), address(usdc), 500e6);
    }

    function test_WithdrawAssetToUser_ZeroAsset() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(InvalidAsset.selector));
        wallet.withdrawAssetToUser(recipient, address(0), 500e6);
    }

    function test_WithdrawAssetToUser_OnlyOwner() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
    }

    function test_WithdrawAssetToUser_InsufficientBalance() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector));
        wallet.withdrawAssetToUser(recipient, address(usdc), 10_000e6);
    }

    function test_WithdrawAssetToUser_BaseAsset_RespectsFees() public {
        vm.prank(admin);
        feeTracker.setFeeConfig(1000, admin);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareDeposit(address(vault), 1_000e6, 1_000e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareWithdraw(address(vault), 1_000e6, 1_100e6);

        assertEq(feeTracker.getFeesOwed(address(wallet)), 10e6);

        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector));
        wallet.withdrawAssetToUser(recipient, address(usdc), 1_000e6);

        vm.prank(ownerAddr);
        wallet.withdrawAssetToUser(recipient, address(usdc), 990e6);

        assertEq(usdc.balanceOf(recipient), 990e6);
    }

    function test_WithdrawAllAssetToUser_BaseAsset_RespectsFees() public {
        vm.prank(admin);
        feeTracker.setFeeConfig(1000, admin);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareDeposit(address(vault), 1_000e6, 1_000e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareWithdraw(address(vault), 1_000e6, 1_100e6);

        vm.prank(ownerAddr);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));

        assertEq(usdc.balanceOf(recipient), 990e6);
        assertEq(usdc.balanceOf(address(wallet)), 10e6);
    }

    function test_WithdrawAssetToUser_NonBaseAsset_Reverts() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER");
        otherToken.mint(address(wallet), 500e6);

        vm.prank(ownerAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(otherToken), 500e6);
    }

    function test_WithdrawAllAssetToUser_EmptyBalance() public {
        vm.prank(ownerAddr);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));
        uint256 recipientBalance = usdc.balanceOf(recipient);

        vm.prank(ownerAddr);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));

        assertEq(usdc.balanceOf(recipient), recipientBalance);
    }

    function test_WithdrawAllAssetToUser_ZeroRecipient() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        wallet.withdrawAllAssetToUser(address(0), address(usdc));
    }

    function test_WithdrawAllAssetToUser_ZeroAsset() public {
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(InvalidAsset.selector));
        wallet.withdrawAllAssetToUser(recipient, address(0));
    }

    function test_WithdrawAllAssetToUser_OnlyOwner() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.withdrawAllAssetToUser(recipient, address(usdc));
    }

    function test_WithdrawAllAssetToUser_NonBaseAsset_Reverts() public {
        MockERC20 otherToken = new MockERC20("Other Token", "OTHER");
        otherToken.mint(address(wallet), 500e6);

        vm.prank(ownerAddr);
        vm.expectRevert();
        wallet.withdrawAllAssetToUser(recipient, address(otherToken));
    }

    function test_WithdrawEthToUser_ValidAmount() public {
        uint256 amount = 1 ether;
        vm.deal(address(wallet), amount);

        vm.expectEmit(true, true, false, true);
        emit WithdrewEthToUser(ownerAddr, recipient, amount);
        vm.prank(ownerAddr);
        wallet.withdrawEthToUser(recipient, amount);

        assertEq(recipient.balance, amount);
    }

    function test_WithdrawEthToUser_ZeroAmount() public {
        vm.prank(ownerAddr);
        wallet.withdrawEthToUser(recipient, 0);

        assertEq(recipient.balance, 0);
    }

    function test_WithdrawEthToUser_InsufficientBalance() public {
        vm.prank(ownerAddr);
        vm.expectRevert();
        wallet.withdrawEthToUser(recipient, 1 ether);
    }

    function test_WithdrawEthToUser_OnlyOwner() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.withdrawEthToUser(recipient, 1 ether);
    }

    // ============ Sync and upgrade parity coverage ============

    function test_SyncFromFactory_OwnerCanCall() public {
        vm.prank(ownerAddr);
        wallet.syncFromFactory();

        assertEq(address(wallet.adapterRegistry()), address(registry));
        assertEq(address(wallet.feeTracker()), address(feeTracker));
    }

    function test_SyncFromFactory_NonExecutorReverts() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.syncFromFactory();
    }

    function test_Upgrade_NonOwnerReverts() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.upgradeToAndCall(address(1), "");
    }

    function test_Upgrade_UnapprovedImplementationReverts() public {
        vm.prank(ownerAddr);
        vm.expectRevert();
        wallet.upgradeToAndCall(address(1), "");
    }

    function test_Upgrade_PreservesStorage() public {
        address blockedAdapter = makeAddr("upgradeBlockedAdapter");
        vm.prank(ownerAddr);
        wallet.blockAdapter(blockedAdapter);

        AgentWalletV2 nextImplementation;
        vm.prank(admin);
        nextImplementation = new AgentWalletV2(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(AWKAgentWalletV1(payable(address(nextImplementation))));

        vm.prank(ownerAddr);
        wallet.upgradeToAndCall(address(nextImplementation), "");

        assertEq(wallet.owner(), ownerAddr);
        assertEq(address(wallet.baseAsset()), address(usdc));
        assertTrue(wallet.isAdapterBlocked(blockedAdapter));
        assertEq(_implementation(), address(nextImplementation));
    }

    // ============ Helpers ============

    function _ownerActionCallData() internal view returns (bytes[] memory calls) {
        calls = new bytes[](10);
        calls[0] = abi.encodeWithSelector(wallet.blockAdapter.selector, address(vaultAdapter));
        calls[1] = abi.encodeWithSelector(wallet.unblockAdapter.selector, address(vaultAdapter));
        calls[2] = abi.encodeWithSelector(wallet.blockTarget.selector, address(vault));
        calls[3] = abi.encodeWithSelector(wallet.unblockTarget.selector, address(vault));
        calls[4] = abi.encodeWithSelector(wallet.withdrawAssetToUser.selector, recipient, address(usdc), 500e6);
        calls[5] = abi.encodeWithSelector(wallet.withdrawAllAssetToUser.selector, recipient, address(usdc));
        calls[6] = abi.encodeWithSelector(wallet.withdrawEthToUser.selector, recipient, 0.1 ether);
        calls[7] = abi.encodeWithSelector(wallet.withdrawAllEthToUser.selector, recipient);
        calls[8] = abi.encodeWithSelector(wallet.upgradeToLatest.selector);
        calls[9] = abi.encodeWithSelector(wallet.upgradeToAndCall.selector, address(1), bytes(""));
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(wallet), IMPLEMENTATION_SLOT))));
    }

    function _withdrawCallData() internal view returns (bytes memory) {
        return abi.encodeWithSelector(wallet.withdrawAssetToUser.selector, recipient, address(usdc), 500e6);
    }

    function _validateWithSigner(bytes memory callData, uint256 signerKey) internal returns (uint256) {
        bytes32 userOpHash = keccak256(abi.encode(callData, block.timestamp));
        UserOperation memory userOp = _buildUserOp(callData, _sign(signerKey, userOpHash));
        vm.prank(ENTRY_POINT);
        return wallet.validateUserOp(userOp, userOpHash, 0);
    }

    function _buildUserOp(bytes memory callData, bytes memory signature) internal view returns (UserOperation memory) {
        return UserOperation({
            sender: address(wallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 500000,
            verificationGasLimit: 500000,
            preVerificationGas: 21000,
            maxFeePerGas: 1000000000,
            maxPriorityFeePerGas: 1000000000,
            paymasterAndData: "",
            signature: signature
        });
    }

    function _sign(uint256 privateKey, bytes32 userOpHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, userOpHash.toEthSignedMessageHash());
        return abi.encodePacked(r, s, v);
    }
}
