pragma solidity 0.8.38;

import {InvalidAsset, YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AdapterExecutionFailed, AdapterIsBlocked, InvalidState, NotAllowed, NotApprovedImplementation, TargetIsBlocked, TransferFailed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IAWKAdapter} from "../../src/agentwalletkit/IAWKAdapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {MockAgentWalletV3} from "../mocks/MockAgentWalletV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC1967ProxyUnsafe} from "@openzeppelin/contracts/mocks/proxy/ERC1967ProxyUnsafe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

/// @notice A contract owner (like a Safe with an on-chain approved message) that approves exactly the hashes it was told to
contract ApprovedHashOwner {
    mapping(bytes32 hash => bool) public approved;

    function approve(bytes32 hash) external {
        approved[hash] = true;
    }

    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        return approved[hash] ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract RevertingFeeQueriesModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address feeTracker_, bytes32 feeType_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        revert();
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        revert();
    }
}

contract GasBurningFeeQueriesModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address feeTracker_, bytes32 feeType_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool accounted) {
        accounted = false;
        while (true) {}
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256 owed) {
        owed = 0;
        while (true) {}
    }
}

contract FeeActionFailureModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;
    bool private immutable _burnsGas;

    constructor(address feeTracker_, bytes32 feeType_, bool burnsGas_) {
        FEE_TRACKER = feeTracker_;
        FEE_TYPE = feeType_;
        _burnsGas = burnsGas_;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external view override returns (uint256) {
        if (_burnsGas) {
            while (true) {}
        }
        revert();
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        return 0;
    }
}

contract NestedDelegatecallAdapter is IAWKAdapter {
    function execute(address, bytes calldata data) external payable override returns (bytes memory result) {
        (bool success, bytes memory returndata) = address(this).delegatecall(data);
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }
}

contract WalletIntegrationTest is IntegrationBase {
    using MessageHashUtils for bytes32;

    address private constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address private constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address private constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    address private constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    address private constant SPONSORING_PAYMASTER = 0x9A9A9A9a9A9A9A9a9A9a9a9A9A9a9A9a9A9A9a9a;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;
    uint256 private constant SIG_VALIDATION_FAILED = 1;

    address private _walletOwner;
    uint256 private _ownerKey;
    address private _signedOperator;
    uint256 private _signedOperatorKey;
    address private _recipient;
    AgentWallet private _wallet;

    function setUp() public override {
        super.setUp();
        (_walletOwner, _ownerKey) = makeAddrAndKey("wallet owner");
        (_signedOperator, _signedOperatorKey) = makeAddrAndKey("wallet operator");
        _recipient = makeAddr("wallet recipient");
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), _signedOperator);
        _wallet = _createVaultWallet(_walletOwner, 1);
        _fundWallet(_wallet, address(usdc), 1_000e6);
    }

    function test_SameOwnerProfileWalletsKeepIndependentState() public {
        AgentWallet firstWallet = _createVaultWallet(_walletOwner, 2);
        AgentWallet secondWallet = _createVaultWallet(_walletOwner, 3);
        _fundWallet(firstWallet, address(usdc), 100e6);
        _fundWallet(secondWallet, address(usdc), 200e6);

        _execute(firstWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        _execute(secondWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (150e6)));

        assertTrue(address(firstWallet) != address(secondWallet));
        assertEq(firstWallet.ownerAgentIndex(), 2);
        assertEq(secondWallet.ownerAgentIndex(), 3);
        assertEq(erc4626Vault.balanceOf(address(firstWallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(secondWallet)), 150e6);
        assertEq(vaultYieldFeeModule.costBasis(address(firstWallet), address(erc4626Vault)), 100e6);
        assertEq(vaultYieldFeeModule.costBasis(address(secondWallet), address(erc4626Vault)), 150e6);

        vm.prank(_walletOwner);
        firstWallet.blockAdapter(address(erc4626Adapter));
        assertTrue(firstWallet.isAdapterBlocked(address(erc4626Adapter)));
        assertFalse(secondWallet.isAdapterBlocked(address(erc4626Adapter)));
    }

    function test_OperatorExecutesAdaptersButCannotCallOwnerFunctions() public {
        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        assertGt(erc4626Vault.balanceOf(address(_wallet)), 0);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        _wallet.withdrawAssetToUser(_recipient, address(usdc), 1);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        _wallet.blockAdapter(address(erc4626Adapter));

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        _wallet.settleFeesForWithdrawal(address(usdc), _recipient, 1);

        vm.expectRevert(NotAllowed.selector);
        vm.prank(_walletOwner);
        _wallet.execute(address(usdc), 0, "");

        vm.expectRevert(NotAllowed.selector);
        vm.prank(_walletOwner);
        _wallet.executeBatch(new address[](0), new bytes[](0));

        vm.prank(_walletOwner);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        assertGt(erc4626Vault.balanceOf(address(_wallet)), 100e6);
    }

    function test_UninitializedProxyCannotUseTheInitializerWithoutBaseAsset() public {
        AgentWallet uninitialized = AgentWallet(payable(address(new ERC1967ProxyUnsafe(address(walletImplementation), ""))));
        vm.expectRevert(NotAllowed.selector);
        uninitialized.initialize(_walletOwner, 0, VAULT_AGENT_PROFILE);
        assertEq(uninitialized.owner(), address(0));
    }

    function test_UserOperationValidationRestrictsOperatorToAdapterSelectors() public {
        bytes[] memory ownerCalls = new bytes[](13);
        ownerCalls[0] = abi.encodeWithSelector(_wallet.blockAdapter.selector, address(erc4626Adapter));
        ownerCalls[1] = abi.encodeWithSelector(_wallet.unblockAdapter.selector, address(erc4626Adapter));
        ownerCalls[2] = abi.encodeWithSelector(_wallet.blockTarget.selector, address(erc4626Vault));
        ownerCalls[3] = abi.encodeWithSelector(_wallet.unblockTarget.selector, address(erc4626Vault));
        ownerCalls[4] = abi.encodeWithSelector(_wallet.withdrawAssetToUser.selector, _recipient, address(usdc), 1);
        ownerCalls[5] = abi.encodeWithSelector(_wallet.withdrawAllAssetToUser.selector, _recipient, address(usdc));
        ownerCalls[6] = abi.encodeWithSelector(_wallet.withdrawAssetsToUser.selector, _recipient, new address[](0), new uint256[](0));
        ownerCalls[7] = abi.encodeWithSelector(_wallet.withdrawAllAssetsToUser.selector, _recipient, new address[](0));
        ownerCalls[8] = abi.encodeWithSelector(_wallet.withdrawEthToUser.selector, _recipient, 1);
        ownerCalls[9] = abi.encodeWithSelector(_wallet.withdrawAllEthToUser.selector, _recipient);
        ownerCalls[10] = abi.encodeWithSelector(_wallet.upgradeToLatest.selector);
        ownerCalls[11] = abi.encodeWithSelector(_wallet.upgradeToAndCall.selector, address(1), bytes(""));
        ownerCalls[12] = abi.encodeWithSelector(_wallet.syncFromFactory.selector);

        for (uint256 i; i < ownerCalls.length; ++i) {
            assertEq(_validateWithSigner(_wallet, ownerCalls[i], _ownerKey), SIG_VALIDATION_SUCCESS);
            assertEq(_validateWithSigner(_wallet, ownerCalls[i], _signedOperatorKey), SIG_VALIDATION_FAILED);
        }

        bytes memory adapterCall = abi.encodeWithSelector(_wallet.executeViaAdapter.selector, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        assertEq(_validateWithSigner(_wallet, adapterCall, _signedOperatorKey), SIG_VALIDATION_SUCCESS);
        assertEq(_validateWithSigner(_wallet, adapterCall, _ownerKey), SIG_VALIDATION_SUCCESS);
        (address stranger, uint256 strangerKey) = makeAddrAndKey("wallet stranger");
        assertTrue(stranger != _walletOwner && stranger != _signedOperator);
        assertEq(_validateWithSigner(_wallet, ownerCalls[4], strangerKey), SIG_VALIDATION_FAILED);
        assertEq(_validateWithSigner(_wallet, adapterCall, strangerKey), SIG_VALIDATION_FAILED);

        address[] memory adapters = new address[](1);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);
        adapters[0] = address(erc4626Adapter);
        targets[0] = address(erc4626Vault);
        datas[0] = abi.encodeCall(erc4626Adapter.deposit, (100e6));
        bytes memory batchCall = abi.encodeWithSelector(_wallet.executeViaAdapterBatch.selector, adapters, targets, datas);
        assertEq(_validateWithSigner(_wallet, batchCall, _signedOperatorKey), SIG_VALIDATION_SUCCESS);

        UserOperation memory userOp = _buildUserOp(_wallet, "", "");
        vm.expectRevert("account: not from EntryPoint");
        _wallet.validateUserOp(userOp, bytes32(0), 0);

        vm.prank(ENTRY_POINT);
        _wallet.withdrawAssetToUser(_recipient, address(usdc), 100e6);
        assertEq(usdc.balanceOf(_recipient), 100e6);
    }

    function test_UserOperationValidationFailsMalformedSignaturesAndShortOperatorCallData() public {
        bytes memory callData = abi.encodeWithSelector(_wallet.withdrawAssetToUser.selector, _recipient, address(usdc), 1);
        bytes32 userOpHash = keccak256(abi.encode(callData, vm.getBlockTimestamp()));
        UserOperation memory userOp = _buildUserOp(_wallet, callData, "");

        vm.prank(ENTRY_POINT);
        assertEq(_wallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_FAILED);

        userOp.signature = hex"1234";
        vm.prank(ENTRY_POINT);
        assertEq(_wallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_FAILED);

        userOp.signature = abi.encodePacked(bytes32(uint256(1)), bytes32(type(uint256).max), uint8(27));
        vm.prank(ENTRY_POINT);
        assertEq(_wallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_FAILED);

        assertEq(_validateWithSigner(_wallet, "", _signedOperatorKey), SIG_VALIDATION_FAILED);

        vm.expectRevert("account: not from EntryPoint");
        _wallet.validateUserOp(userOp, userOpHash, 0);
    }

    function test_ContractOwnerAuthorizesUserOperationsThroughERC1271() public {
        ApprovedHashOwner contractOwner = new ApprovedHashOwner();
        AgentWallet contractOwnedWallet = _createVaultWallet(address(contractOwner), 1);
        uint256 amount = 100e6;
        _fundWallet(contractOwnedWallet, address(usdc), amount);
        bytes memory withdrawCall = abi.encodeCall(contractOwnedWallet.withdrawAssetToUser, (_recipient, address(usdc), amount));
        bytes32 userOpHash = keccak256(abi.encode(withdrawCall, vm.getBlockTimestamp()));
        UserOperation memory userOp = _buildUserOp(contractOwnedWallet, withdrawCall, "");

        vm.prank(ENTRY_POINT);
        assertEq(contractOwnedWallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_FAILED);

        contractOwner.approve(userOpHash.toEthSignedMessageHash());
        vm.prank(ENTRY_POINT);
        assertEq(contractOwnedWallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_SUCCESS);
        vm.prank(ENTRY_POINT);
        contractOwnedWallet.withdrawAssetToUser(_recipient, address(usdc), amount);
        assertEq(usdc.balanceOf(_recipient), amount);

        bytes memory adapterCall = abi.encodeCall(contractOwnedWallet.executeViaAdapter, (address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (1e6))));
        assertEq(_validateWithSigner(contractOwnedWallet, abi.encodeCall(contractOwnedWallet.withdrawAssetToUser, (_recipient, address(usdc), 1)), _signedOperatorKey), SIG_VALIDATION_FAILED);
        vm.expectCall(address(contractOwner), abi.encodeWithSelector(ApprovedHashOwner.isValidSignature.selector), 0);
        assertEq(_validateWithSigner(contractOwnedWallet, adapterCall, _signedOperatorKey), SIG_VALIDATION_SUCCESS);
    }

    function test_OperatorUserOperationsNeedAPaymasterAndAdapterCallsNeverReachERC1271() public {
        bytes memory adapterCall = abi.encodeCall(_wallet.executeViaAdapter, (address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (1e6))));
        bytes32 userOpHash = keccak256("unsponsored operator op");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signedOperatorKey, userOpHash.toEthSignedMessageHash());
        UserOperation memory userOp = _buildUserOp(_wallet, adapterCall, abi.encodePacked(r, s, v));
        bytes[2] memory unsponsored = [bytes(""), abi.encodePacked(address(0))];
        bytes[2] memory packedUnsponsored = [bytes(""), abi.encodePacked(address(0), uint128(100_000), uint128(0))];
        for (uint256 i; i < 2; ++i) {
            userOp.paymasterAndData = unsponsored[i];
            vm.prank(ENTRY_POINT);
            assertEq(_wallet.validateUserOp(userOp, userOpHash, 0), SIG_VALIDATION_FAILED);
            PackedUserOperation memory packedUserOp = _buildPackedUserOp(adapterCall, abi.encodePacked(r, s, v));
            packedUserOp.paymasterAndData = packedUnsponsored[i];
            vm.prank(ENTRY_POINT_V07);
            assertEq(_wallet.validateUserOp(packedUserOp, userOpHash, 0), SIG_VALIDATION_FAILED);
        }

        UserOperation memory onImplementation = _buildUserOp(AgentWallet(payable(address(walletImplementation))), abi.encodeCall(_wallet.withdrawAllEthToUser, (_recipient)), hex"1234");
        vm.prank(ENTRY_POINT);
        assertEq(AgentWallet(payable(address(walletImplementation))).validateUserOp(onImplementation, userOpHash, 0), SIG_VALIDATION_FAILED);

        ApprovedHashOwner contractOwner = new ApprovedHashOwner();
        AgentWallet contractOwnedWallet = _createVaultWallet(address(contractOwner), 2);
        UserOperation memory dummy = _buildUserOp(contractOwnedWallet, adapterCall, new bytes(65));
        contractOwner.approve(userOpHash.toEthSignedMessageHash());
        vm.expectCall(address(contractOwner), abi.encodeWithSelector(ApprovedHashOwner.isValidSignature.selector), 0);
        vm.prank(ENTRY_POINT);
        assertEq(contractOwnedWallet.validateUserOp(dummy, userOpHash, 0), SIG_VALIDATION_FAILED);
    }

    function test_PackedEntryPointsValidateWithTheSameRulesAndActAsEntryPoint() public {
        address[3] memory packedEntryPoints = [ENTRY_POINT_V07, ENTRY_POINT_V08, ENTRY_POINT_V09];
        bytes memory withdrawCall = abi.encodeCall(_wallet.withdrawAssetToUser, (_recipient, address(usdc), 1));
        bytes memory adapterCall = abi.encodeCall(_wallet.executeViaAdapter, (address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (1e6))));
        (, uint256 strangerKey) = makeAddrAndKey("packed stranger");
        vm.deal(address(_wallet), 1 ether);
        for (uint256 i; i < packedEntryPoints.length; ++i) {
            address entryPoint = packedEntryPoints[i];
            assertTrue(_wallet.isEntryPoint(entryPoint));
            assertEq(_validatePackedWithSigner(entryPoint, withdrawCall, _ownerKey, 0), SIG_VALIDATION_SUCCESS);
            assertEq(_validatePackedWithSigner(entryPoint, withdrawCall, _signedOperatorKey, 0), SIG_VALIDATION_FAILED);
            assertEq(_validatePackedWithSigner(entryPoint, adapterCall, _signedOperatorKey, 0), SIG_VALIDATION_SUCCESS);
            assertEq(_validatePackedWithSigner(entryPoint, adapterCall, strangerKey, 0), SIG_VALIDATION_FAILED);

            uint256 entryPointBalance = entryPoint.balance;
            _validatePackedWithSigner(entryPoint, adapterCall, _signedOperatorKey, 0.01 ether);
            assertEq(entryPoint.balance - entryPointBalance, 0.01 ether);

            vm.prank(entryPoint);
            _wallet.withdrawAssetToUser(_recipient, address(usdc), 1);
        }
        assertEq(usdc.balanceOf(_recipient), 3);

        assertFalse(_wallet.isEntryPoint(_recipient));
        PackedUserOperation memory userOp = _buildPackedUserOp(withdrawCall, "");
        vm.prank(ENTRY_POINT);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, ENTRY_POINT));
        _wallet.validateUserOp(userOp, bytes32(0), 0);
        vm.prank(_recipient);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, _recipient));
        _wallet.withdrawAssetToUser(_recipient, address(usdc), 1);
    }

    function test_StorageSlotsStayFixedForUpgrades() public view {
        bytes32 walletSlot = keccak256("agentwalletkit.agentwallet.storage.v1");
        bytes32 extensionSlot = keccak256("yieldseeker.agentwallet.extensions.v1");
        assertEq(_storedAddress(walletSlot, 0), _walletOwner);
        assertEq(uint256(vm.load(address(_wallet), bytes32(uint256(walletSlot) + 1))), _wallet.ownerAgentIndex());
        assertEq(_storedAddress(walletSlot, 2), address(_wallet.adapterRegistry()));
        assertEq(vm.load(address(_wallet), bytes32(uint256(walletSlot) + 7)), _wallet.agentProfile());
        assertEq(_storedAddress(extensionSlot, 0), address(usdc));
        assertEq(_storedAddress(extensionSlot, 1), address(_wallet.feeTracker()));
        assertEq(_storedAddress(extensionSlot, 2), address(_wallet.swapPolicy()));
    }

    function _storedAddress(bytes32 base, uint256 offset) private view returns (address) {
        return address(uint160(uint256(vm.load(address(_wallet), bytes32(uint256(base) + offset)))));
    }

    function test_EmergencyOperatorRemovalReachesWalletsThroughAnyonesSync() public {
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (100e6));
        address stranger = makeAddr("sync stranger");
        bytes memory notEmergency = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, factory.EMERGENCY_ROLE());
        vm.expectRevert(notEmergency);
        vm.prank(stranger);
        factory.removeAgentOperator(operator);

        factory.removeAgentOperator(operator);
        assertFalse(factory.hasRole(factory.AGENT_OPERATOR_ROLE(), operator));
        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), depositData);

        vm.prank(stranger);
        _wallet.syncFromFactory();

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        vm.prank(_signedOperator);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(erc4626Vault.balanceOf(address(_wallet)), 200e6);
    }

    function test_AdapterBlocklistsRegistryChecksAndExecutionFailure() public {
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (100e6));

        vm.prank(_walletOwner);
        _wallet.blockAdapter(address(erc4626Adapter));
        vm.expectRevert(abi.encodeWithSelector(AdapterIsBlocked.selector, address(erc4626Adapter)));
        vm.prank(operator);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        vm.prank(_walletOwner);
        _wallet.unblockAdapter(address(erc4626Adapter));

        vm.prank(_walletOwner);
        _wallet.blockTarget(address(erc4626Vault));
        vm.expectRevert(abi.encodeWithSelector(TargetIsBlocked.selector, address(erc4626Vault)));
        vm.prank(operator);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        vm.prank(_walletOwner);
        _wallet.unblockTarget(address(erc4626Vault));

        address unregisteredAdapter = address(0xCAFE);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, unregisteredAdapter));
        vm.prank(operator);
        _wallet.executeViaAdapter(unregisteredAdapter, address(erc4626Vault), depositData);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter)));
        vm.prank(operator);
        _wallet.executeViaAdapter(address(erc4626Adapter), address(0xCAFE), depositData);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, address(0xCAFE)));
        vm.prank(address(0xCAFE));
        _wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);

        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), depositData);
        assertGt(erc4626Vault.balanceOf(address(_wallet)), 0);
    }

    function test_ReentrancyGuardBlocksNestedOwnerAndExecutorCalls() public {
        NestedDelegatecallAdapter nestedAdapter = new NestedDelegatecallAdapter();
        _registerTarget(vaultRegistry, address(nestedAdapter), address(nestedAdapter));

        _executeExpectRevert(
            _wallet,
            address(nestedAdapter),
            address(nestedAdapter),
            abi.encodeWithSelector(_wallet.withdrawAssetToUser.selector, _recipient, address(usdc), 100e6),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(usdc.balanceOf(_recipient), 0);

        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (100e6));
        _executeExpectRevert(
            _wallet,
            address(nestedAdapter),
            address(nestedAdapter),
            abi.encodeWithSelector(_wallet.executeViaAdapter.selector, address(erc4626Adapter), address(erc4626Vault), depositData),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );

        address[] memory nestedAdapters = new address[](1);
        address[] memory nestedTargets = new address[](1);
        bytes[] memory nestedDatas = new bytes[](1);
        nestedAdapters[0] = address(erc4626Adapter);
        nestedTargets[0] = address(erc4626Vault);
        nestedDatas[0] = depositData;
        bytes memory nestedBatch = abi.encodeWithSelector(_wallet.executeViaAdapterBatch.selector, nestedAdapters, nestedTargets, nestedDatas);
        address[] memory adapters = new address[](1);
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);
        adapters[0] = address(nestedAdapter);
        targets[0] = address(nestedAdapter);
        datas[0] = nestedBatch;
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)));
        vm.prank(operator);
        _wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(erc4626Vault.balanceOf(address(_wallet)), 0);
    }

    function test_BatchExecutionRollsBackEarlierCallsWhenLaterAdapterFails() public {
        AgentWallet batchWallet = _createVaultWallet(_walletOwner, 2);
        _fundWallet(batchWallet, address(usdc), 200e6);

        vm.expectRevert(InvalidState.selector);
        vm.prank(operator);
        batchWallet.executeViaAdapterBatch(new address[](1), new address[](0), new bytes[](1));

        vm.prank(operator);
        bytes[] memory emptyResults = batchWallet.executeViaAdapterBatch(new address[](0), new address[](0), new bytes[](0));
        assertEq(emptyResults.length, 0);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(merklAdapter);
        targets[0] = address(erc4626Vault);
        targets[1] = address(merklDistributor);
        datas[0] = abi.encodeCall(erc4626Adapter.deposit, (50e6));

        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes32[][] memory proofs = new bytes32[][](1);
        tokens[0] = address(rewardToken);
        amounts[0] = 10e18;
        proofs[0] = new bytes32[](0);
        datas[1] = abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs));

        vm.prank(operator);
        bytes[] memory results = batchWallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(results.length, 2);
        assertEq(erc4626Vault.balanceOf(address(batchWallet)), 50e6);
        assertEq(usdc.balanceOf(address(batchWallet)), 150e6);
        assertEq(rewardToken.balanceOf(address(batchWallet)), 10e18);

        uint256 sharesBefore = erc4626Vault.balanceOf(address(batchWallet));
        uint256 walletBalanceBefore = usdc.balanceOf(address(batchWallet));
        uint256 vaultBalanceBefore = usdc.balanceOf(address(erc4626Vault));
        adapters[1] = address(erc4626Adapter);
        targets[1] = address(erc4626Vault);
        datas[0] = abi.encodeCall(erc4626Adapter.deposit, (100e6));
        datas[1] = abi.encodeCall(erc4626Adapter.deposit, (0));
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, abi.encodeWithSelector(AWKErrors.ZeroAmount.selector)));
        vm.prank(operator);
        batchWallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(erc4626Vault.balanceOf(address(batchWallet)), sharesBefore);
        assertEq(usdc.balanceOf(address(batchWallet)), walletBalanceBefore);
        assertEq(usdc.balanceOf(address(erc4626Vault)), vaultBalanceBefore);
        assertEq(rewardToken.balanceOf(address(batchWallet)), 10e18);
    }

    function test_AdapterFailureDoesNotLeaveWalletLocked() public {
        _executeExpectRevert(_wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));

        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        assertGt(erc4626Vault.balanceOf(address(_wallet)), 0);
    }

    function test_BaseAssetWithdrawalSettlesYieldFeesAndTransfersExactAmount() public {
        AgentWallet yieldWallet = _createVaultWallet(_walletOwner, 2);
        _accrueVaultYield(yieldWallet, 100e6, 10e6);
        uint256 fee = 1e6;
        uint256 available = 109e6;

        assertEq(vaultYieldFeeModule.feesOwed(address(yieldWallet)), 0);
        assertEq(usdc.balanceOf(address(yieldWallet)), available);
        assertEq(yieldWallet.withdrawableBalance(address(usdc)), available);

        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        vm.prank(_walletOwner);
        yieldWallet.withdrawAssetToUser(_recipient, address(usdc), available + fee);
        assertEq(usdc.balanceOf(feeCollector), 1e6);
        assertEq(usdc.balanceOf(address(yieldWallet)), available);

        vm.prank(_walletOwner);
        yieldWallet.withdrawAssetToUser(_recipient, address(usdc), available);
        assertEq(usdc.balanceOf(_recipient), available);
        assertEq(usdc.balanceOf(address(yieldWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), 1e6);
    }

    function test_WithdrawAllTransfersAllAvailableBaseAsset() public {
        AgentWallet yieldWallet = _createVaultWallet(_walletOwner, 2);
        _accrueVaultYield(yieldWallet, 100e6, 10e6);
        vm.prank(_walletOwner);
        yieldWallet.withdrawAllAssetToUser(_recipient, address(usdc));
        assertEq(usdc.balanceOf(_recipient), 109e6);
        assertEq(usdc.balanceOf(address(yieldWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), 1e6);
    }

    function test_BatchWithdrawAllSettlesBorrowFeesAndTransfersBothAssets() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(10);
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAllAssetsToUser(_recipient, assets);

        assertEq(usdc.balanceOf(_recipient), 20e6 - feeOwed);
        assertEq(weth.balanceOf(_recipient), 1e18);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function test_BatchWithdrawAssetsTransfersExactAmountsAndRevertsAtomically() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(11);
        MockERC20 unrelated = new MockERC20("Unrelated", "NOPE");
        _fundWallet(borrowWallet, address(unrelated), 5e6);
        assertFalse(borrowFeeTracker.isAccountedToken(address(borrowWallet), address(unrelated)));

        address[] memory mismatchAssets = new address[](2);
        mismatchAssets[0] = address(usdc);
        mismatchAssets[1] = address(weth);
        uint256[] memory mismatchAmounts = new uint256[](1);
        mismatchAmounts[0] = 5e6;
        vm.expectRevert(InvalidState.selector);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetsToUser(_recipient, mismatchAssets, mismatchAmounts);

        address[] memory invalidAssets = new address[](2);
        invalidAssets[0] = address(usdc);
        invalidAssets[1] = address(unrelated);
        uint256[] memory invalidAmounts = new uint256[](2);
        invalidAmounts[0] = 5e6;
        invalidAmounts[1] = 5e6;
        vm.expectRevert(InvalidAsset.selector);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetsToUser(_recipient, invalidAssets, invalidAmounts);

        assertEq(usdc.balanceOf(_recipient), 0);
        assertEq(weth.balanceOf(_recipient), 0);
        assertEq(unrelated.balanceOf(_recipient), 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 20e6);
        assertEq(weth.balanceOf(address(borrowWallet)), 1e18);
        assertEq(unrelated.balanceOf(address(borrowWallet)), 5e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), feeOwed);

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 1e18;
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetsToUser(_recipient, assets, amounts);

        assertEq(usdc.balanceOf(_recipient), 5e6);
        assertEq(weth.balanceOf(_recipient), 1e18);
        assertEq(unrelated.balanceOf(_recipient), 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 15e6 - feeOwed);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
        assertEq(unrelated.balanceOf(address(borrowWallet)), 5e6);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function test_BorrowedAssetIsAccountedAndWithdrawalSettlesBaseAssetFees() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(3);

        assertTrue(borrowFeeTracker.isAccountedToken(address(borrowWallet), address(weth)));
        assertEq(borrowWallet.withdrawableBalance(address(weth)), 1e18);
        assertEq(borrowWallet.withdrawableBalance(address(usdc)), 20e6 - feeOwed);

        MockERC20 unrelated = new MockERC20("Unrelated", "NOPE");
        _fundWallet(borrowWallet, address(unrelated), 5e6);
        assertFalse(borrowFeeTracker.isAccountedToken(address(borrowWallet), address(unrelated)));
        assertEq(borrowWallet.withdrawableBalance(address(unrelated)), 0);
        vm.expectRevert(InvalidAsset.selector);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(unrelated), 1e6);

        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(usdc), 20e6 - feeOwed + 1);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), feeOwed);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 20e6);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(usdc), 5e6);
        assertEq(usdc.balanceOf(_recipient), 5e6);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
        assertEq(usdc.balanceOf(address(borrowWallet)), 15e6 - feeOwed);
        assertEq(borrowWallet.withdrawableBalance(address(usdc)), 15e6 - feeOwed);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAllAssetToUser(_recipient, address(usdc));
        assertEq(usdc.balanceOf(_recipient), 20e6 - feeOwed);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(weth), 1e18);
        assertEq(weth.balanceOf(_recipient), 1e18);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
    }

    function test_WithdrawAllSettlesOutstandingBorrowFee() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(8);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAllAssetToUser(_recipient, address(usdc));

        assertEq(usdc.balanceOf(_recipient), 20e6 - feeOwed);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function test_WithdrawAllPaysOnlyAvailableBorrowFees() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(9, 5e6);
        assertEq(feeOwed, 10e6);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAllAssetToUser(_recipient, address(usdc));

        assertEq(usdc.balanceOf(_recipient), 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), 5e6);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 5e6);
    }

    function test_FailingFeeQueriesDoNotBlockTrackedAssetWithdrawal() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(4);
        bytes32 revertingFeeType = keccak256("integration reverting fee queries");
        bytes32 gasBurningFeeType = keccak256("integration gas burning fee queries");
        RevertingFeeQueriesModule revertingQueries = new RevertingFeeQueriesModule(address(borrowFeeTracker), revertingFeeType);
        GasBurningFeeQueriesModule gasBurningQueries = new GasBurningFeeQueriesModule(address(borrowFeeTracker), gasBurningFeeType);
        borrowFeeTracker.setFeeModule(revertingFeeType, revertingQueries);
        borrowFeeTracker.setFeeModule(gasBurningFeeType, gasBurningQueries);

        MockERC20 unrelated = new MockERC20("Unrelated", "NOPE");
        _fundWallet(borrowWallet, address(unrelated), 5e6);
        assertEq(borrowWallet.withdrawableBalance(address(weth)), 1e18);
        assertEq(borrowWallet.withdrawableBalance(address(usdc)), 20e6 - feeOwed);
        assertFalse(borrowFeeTracker.isAccountedToken(address(borrowWallet), address(unrelated)));
        assertEq(borrowWallet.withdrawableBalance(address(unrelated)), 0);

        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(weth), 1e18);
        assertEq(weth.balanceOf(_recipient), 1e18);
        assertEq(usdc.balanceOf(feeCollector), feeOwed);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function test_RevertingFeeActionCannotBlockOwnerWithdrawal() public {
        _assertFeeActionFailureDoesNotBlockWithdrawal(5, false);
    }

    function test_GasBurningFeeActionCannotBlockOwnerWithdrawal() public {
        _assertFeeActionFailureDoesNotBlockWithdrawal(6, true);
    }

    function test_FeeCollectorTransferFailureCannotBlockOwnerWithdrawal() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(7);
        uint256 borrowedBalance = weth.balanceOf(address(borrowWallet));
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, feeCollector, feeOwed), bytes("fee transfer failed"));

        vm.expectEmit(false, false, false, true, address(borrowWallet));
        emit AgentWallet.FeeSettlementFailed(address(weth), borrowedBalance);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(weth), borrowedBalance);

        assertEq(weth.balanceOf(_recipient), borrowedBalance);
        assertEq(usdc.balanceOf(address(borrowWallet)), 20e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), feeOwed);
    }

    function test_OwnerCannotSkipFeeSettlementWithAnyGasLimit() public {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(8);
        uint256 borrowedBalance = weth.balanceOf(address(borrowWallet));
        bytes memory withdrawal = abi.encodeCall(borrowWallet.withdrawAssetToUser, (_recipient, address(weth), borrowedBalance));
        uint256 successes;
        for (uint256 gasLimit = 60_000; gasLimit <= 3_000_000; gasLimit += 20_000) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(_walletOwner);
            (bool success,) = address(borrowWallet).call{gas: gasLimit}(withdrawal);
            if (success) {
                successes++;
                assertEq(usdc.balanceOf(feeCollector), feeOwed);
                assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
            }
            vm.revertToState(snapshot);
        }
        assertGt(successes, 0);
    }

    function test_BrokenFeeTrackerCannotBlockBaseAssetExit() public {
        uint256 amount = usdc.balanceOf(address(_wallet));
        factory.setFeeTracker(VAULT_AGENT_PROFILE, FeeTracker(address(rewardToken)));
        vm.prank(_walletOwner);
        _wallet.syncFromFactory();

        vm.expectEmit(false, false, false, true, address(_wallet));
        emit AgentWallet.FeeSettlementFailed(address(usdc), amount);
        vm.prank(_walletOwner);
        _wallet.withdrawAssetToUser(_recipient, address(usdc), amount);

        assertEq(usdc.balanceOf(_recipient), amount);
        assertEq(usdc.balanceOf(address(_wallet)), 0);
    }

    function test_WithdrawalValidationAndEthExit() public {
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(_walletOwner);
        _wallet.withdrawAssetToUser(address(0), address(usdc), 1);

        vm.expectRevert(InvalidAsset.selector);
        vm.prank(_walletOwner);
        _wallet.withdrawAssetToUser(_recipient, address(0), 1);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(_walletOwner);
        _wallet.withdrawEthToUser(address(0), 0);

        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        vm.prank(_walletOwner);
        _wallet.withdrawAssetToUser(_recipient, address(usdc), 1_000e6 + 1);
        vm.expectRevert(TransferFailed.selector);
        vm.prank(_walletOwner);
        _wallet.withdrawEthToUser(_recipient, 1);

        uint256 recipientBalance = _recipient.balance;
        vm.deal(address(_wallet), 1 ether);
        vm.prank(_walletOwner);
        _wallet.withdrawEthToUser(_recipient, 0.4 ether);
        assertEq(_recipient.balance, recipientBalance + 0.4 ether);
        vm.prank(_walletOwner);
        _wallet.withdrawAllEthToUser(_recipient);
        assertEq(_recipient.balance, recipientBalance + 1 ether);
    }

    function test_OwnerUpgradeUsesOnlyFactoryApprovedImplementation() public {
        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (100e6)));
        assertEq(vaultYieldFeeModule.costBasis(address(_wallet), address(erc4626Vault)), 100e6);
        vm.prank(_walletOwner);
        _wallet.blockAdapter(address(erc4626Adapter));

        MockAgentWalletV3 approvedImplementation = new MockAgentWalletV3(address(factory));
        AgentWallet unapprovedImplementation = new AgentWallet(address(factory));
        vm.expectRevert(NotApprovedImplementation.selector);
        vm.prank(_walletOwner);
        _wallet.upgradeToAndCall(address(unapprovedImplementation), "");

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, address(0xCAFE)));
        vm.prank(address(0xCAFE));
        _wallet.upgradeToLatest();

        factory.setAgentWalletImplementation(approvedImplementation);
        vm.prank(_walletOwner);
        _wallet.upgradeToLatest();

        assertEq(address(uint160(uint256(vm.load(address(_wallet), IMPLEMENTATION_SLOT)))), address(approvedImplementation));
        assertEq(_wallet.owner(), _walletOwner);
        assertEq(_wallet.ownerAgentIndex(), 1);
        assertEq(address(_wallet.baseAsset()), address(usdc));
        assertTrue(_wallet.isAdapterBlocked(address(erc4626Adapter)));
        assertEq(address(_wallet.adapterRegistry()), address(vaultRegistry));
        assertEq(address(_wallet.feeTracker()), address(vaultFeeTracker));
        assertEq(address(_wallet.swapPolicy()), address(vaultSwapPolicy));
        assertEq(erc4626Vault.balanceOf(address(_wallet)), 100e6);
        assertEq(usdc.balanceOf(address(_wallet)), 900e6);
        assertEq(vaultYieldFeeModule.costBasis(address(_wallet), address(erc4626Vault)), 100e6);
        assertEq(MockAgentWalletV3(payable(address(_wallet))).version(), 3);
        assertEq(MockAgentWalletV3(payable(address(_wallet))).newImplementationSyncs(), 1);
        vm.prank(_walletOwner);
        _wallet.unblockAdapter(address(erc4626Adapter));
        _fund(address(usdc), address(erc4626Vault), 10e6);
        uint256 collectorBalanceBefore = usdc.balanceOf(feeCollector);
        _execute(_wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (100e6)));
        assertEq(usdc.balanceOf(feeCollector) - collectorBalanceBefore, 1e6);
        assertEq(vaultYieldFeeModule.feesOwed(address(_wallet)), 0);
        uint256 remainingBalance = usdc.balanceOf(address(_wallet));
        assertEq(remainingBalance, 1_009e6);

        vm.prank(_walletOwner);
        _wallet.withdrawAllAssetToUser(_recipient, address(usdc));
        assertEq(usdc.balanceOf(_recipient), remainingBalance);
        assertEq(usdc.balanceOf(address(_wallet)), 0);
    }

    function _accrueVaultYield(AgentWallet targetWallet, uint256 depositAmount, uint256 yieldAmount) private {
        _fundWallet(targetWallet, address(usdc), depositAmount);
        _execute(targetWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (depositAmount)));
        uint256 shares = erc4626Vault.balanceOf(address(targetWallet));
        _fund(address(usdc), address(erc4626Vault), yieldAmount);
        _execute(targetWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (shares)));
    }

    function _prepareBorrowWalletWithFees(uint256 index) private returns (AgentWallet borrowWallet, uint256 feeOwed) {
        return _prepareBorrowWalletWithFees(index, 20e6);
    }

    function _prepareBorrowWalletWithFees(uint256 index, uint256 baseFunding) private returns (AgentWallet borrowWallet, uint256 feeOwed) {
        borrowWallet = _createBorrowWallet(_walletOwner, index);
        uint256 collateralAmount = 100e6;
        address marketTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _fundWallet(borrowWallet, address(usdc), collateralAmount);
        _execute(borrowWallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount)));
        _execute(borrowWallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, 1e18)));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _execute(borrowWallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        feeOwed = borrowFeeModule.feesOwed(address(borrowWallet));
        assertGt(feeOwed, 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        _fundWallet(borrowWallet, address(usdc), baseFunding);
    }

    function _assertFeeActionFailureDoesNotBlockWithdrawal(uint256 index, bool burnsGas) private {
        (AgentWallet borrowWallet, uint256 feeOwed) = _prepareBorrowWalletWithFees(index);
        bytes32 feeType = burnsGas ? keccak256("integration gas burning action") : keccak256("integration reverting action");
        FeeActionFailureModule failureModule = new FeeActionFailureModule(address(borrowFeeTracker), feeType, burnsGas);
        borrowFeeTracker.setFeeModule(feeType, failureModule);
        uint256 borrowedBalance = weth.balanceOf(address(borrowWallet));

        vm.expectEmit(false, false, false, true, address(borrowWallet));
        emit AgentWallet.FeeSettlementFailed(address(weth), borrowedBalance);
        vm.prank(_walletOwner);
        borrowWallet.withdrawAssetToUser(_recipient, address(weth), borrowedBalance);

        assertEq(weth.balanceOf(_recipient), borrowedBalance);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(address(borrowWallet)), 20e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), feeOwed);
    }

    function _validateWithSigner(AgentWallet targetWallet, bytes memory callData, uint256 signerKey) private returns (uint256) {
        bytes32 userOpHash = keccak256(abi.encode(callData, vm.getBlockTimestamp()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        UserOperation memory userOp = _buildUserOp(targetWallet, callData, abi.encodePacked(r, s, v));
        vm.prank(ENTRY_POINT);
        return targetWallet.validateUserOp(userOp, userOpHash, 0);
    }

    function _buildUserOp(AgentWallet targetWallet, bytes memory callData, bytes memory signature) private pure returns (UserOperation memory) {
        return UserOperation({
            sender: address(targetWallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 21_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: abi.encodePacked(SPONSORING_PAYMASTER),
            signature: signature
        });
    }

    function _validatePackedWithSigner(address entryPoint, bytes memory callData, uint256 signerKey, uint256 missingAccountFunds) private returns (uint256) {
        bytes32 userOpHash = keccak256(abi.encode(entryPoint, callData, vm.getBlockTimestamp()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        vm.prank(entryPoint);
        return _wallet.validateUserOp(_buildPackedUserOp(callData, abi.encodePacked(r, s, v)), userOpHash, missingAccountFunds);
    }

    function _buildPackedUserOp(bytes memory callData, bytes memory signature) private view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(_wallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(500_000) << 128) | 500_000),
            preVerificationGas: 21_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | 1 gwei),
            paymasterAndData: abi.encodePacked(SPONSORING_PAYMASTER),
            signature: signature
        });
    }
}
