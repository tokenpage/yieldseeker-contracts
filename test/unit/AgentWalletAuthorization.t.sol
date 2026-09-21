// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

/// @title Agent Wallet Authorization Unit Tests
/// @notice Exercises the REAL AWKAgentWalletV1 onlyOwner / _validateSignature logic (not a
///         reimplemented mock): an EntryPoint-relayed UserOperation is authorized only by an
///         owner signature, and an operator signature is only ever valid for the adapter-
///         execution selectors (`executeViaAdapter`/`executeViaAdapterBatch`) — never for any
///         `onlyOwner` function, including withdrawals.
contract AgentWalletAuthorizationTest is Test {
    using MessageHashUtils for bytes32;

    address internal constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;
    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;

    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    MockERC20 usdc;
    MockERC4626 vault;
    AgentWalletV1 wallet;

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
        AgentWalletV1 implementation = new AgentWalletV1(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(implementation);
        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();

        vm.prank(operatorAddr);
        wallet = factory.createAgentWallet(ownerAddr, 1, address(usdc));

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

    function test_ValidateUserOp_WithdrawEthSelector_OperatorSignature_Fails() public {
        bytes memory callData = abi.encodeWithSelector(wallet.withdrawEthToUser.selector, recipient, 1 ether);
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_WithdrawSelector_StrangerSignature_Fails() public {
        uint256 result = _validateWithSigner(_withdrawCallData(), strangerKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    // ============ _validateSignature: sovereignty/upgrade selectors are owner-only too ============

    function test_ValidateUserOp_BlockAdapterSelector_OperatorSignature_Fails() public {
        bytes memory callData = abi.encodeWithSelector(wallet.blockAdapter.selector, address(vaultAdapter));
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_UpgradeToLatestSelector_OperatorSignature_Fails() public {
        bytes memory callData = abi.encodeWithSelector(wallet.upgradeToLatest.selector);
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
    }

    function test_ValidateUserOp_UpgradeToAndCallSelector_OperatorSignature_Fails() public {
        // upgradeToAndCall is OZ's own public UUPS entrypoint (no explicit modifier on the
        // function itself) — authorization is enforced inside _authorizeUpgrade. It must be
        // just as owner-only as upgradeToLatest() when reached via a relayed UserOp, even
        // though its selector differs and it accepts arbitrary post-upgrade callback data.
        bytes memory callData = abi.encodeWithSelector(wallet.upgradeToAndCall.selector, address(0), "");
        uint256 result = _validateWithSigner(callData, operatorKey);
        assertEq(result, SIG_VALIDATION_FAILED);
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

    function test_ValidateUserOp_ExecuteViaAdapterSelector_OwnerSignature_Succeeds() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory callData = abi.encodeWithSelector(wallet.executeViaAdapter.selector, address(vaultAdapter), address(vault), depositData);
        uint256 result = _validateWithSigner(callData, ownerKey);
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

    // ============ onlyOwner: EntryPoint-relayed calls are authorized like a direct owner call ============

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

    function test_EntryPoint_CanCallWithdrawEthToUser() public {
        vm.deal(address(wallet), 1 ether);
        vm.prank(ENTRY_POINT);
        wallet.withdrawEthToUser(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_EntryPoint_CanCallBlockAdapter() public {
        vm.prank(ENTRY_POINT);
        wallet.blockAdapter(address(vaultAdapter));
        assertTrue(wallet.isAdapterBlocked(address(vaultAdapter)));
    }

    function test_EntryPoint_CanCallUpgradeToLatest() public {
        vm.prank(ENTRY_POINT);
        wallet.upgradeToLatest();
    }

    function test_EntryPoint_CanCallUpgradeToAndCall() public {
        address approvedImplementation = address(factory.agentWalletImplementation());
        vm.prank(ENTRY_POINT);
        wallet.upgradeToAndCall(approvedImplementation, "");
    }

    function test_EntryPoint_CannotCallUpgradeToAndCall_WithUnapprovedImplementation() public {
        vm.prank(ENTRY_POINT);
        vm.expectRevert();
        wallet.upgradeToAndCall(address(vaultAdapter), "");
    }

    // ============ onlyOwner: regressions — non-owner, non-EntryPoint callers still rejected ============

    function test_Stranger_CannotCallWithdrawAssetToUser() public {
        vm.prank(strangerAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
    }

    function test_Operator_CannotCallWithdrawAssetToUser_Directly() public {
        // Operators may authorize adapter execution, but have no direct call authority over
        // withdrawals — this must remain true whether or not they hold a valid UserOp signature.
        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.withdrawAssetToUser(recipient, address(usdc), 500e6);
    }

    function test_Operator_CannotCallBlockAdapter_Directly() public {
        vm.prank(operatorAddr);
        vm.expectRevert();
        wallet.blockAdapter(address(vaultAdapter));
    }

    // ============ onlyExecutors: unaffected regression — operators keep direct adapter authority ============

    function test_Operator_CanCallExecuteViaAdapter_Directly() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        vm.prank(operatorAddr);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertGt(vault.balanceOf(address(wallet)), 0);
    }

    // ============ Helpers ============

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
