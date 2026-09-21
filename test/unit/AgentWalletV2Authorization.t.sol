// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV2 as AgentWalletV2} from "../../src/AgentWalletV2.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {AWKAgentWalletV1} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
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
