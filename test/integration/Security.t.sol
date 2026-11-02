pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AdapterExecutionFailed, AdapterIsBlocked, TargetIsBlocked} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IAWKAdapter} from "../../src/agentwalletkit/IAWKAdapter.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface ISecurityWallet {
    function executeViaAdapter(address adapter, address target, bytes calldata data) external returns (bytes memory);
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external;
}

contract ReenterExecuteAdapter is IAWKAdapter {
    function execute(address target, bytes calldata data) external payable override returns (bytes memory result) {
        bytes memory nestedCall = abi.encodeCall(ISecurityWallet.executeViaAdapter, (address(this), target, data));
        (bool success, bytes memory returndata) = address(this).delegatecall(nestedCall);
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }
}

contract ReenterWithdrawAdapter is IAWKAdapter {
    address public immutable usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function execute(address target, bytes calldata) external payable override returns (bytes memory result) {
        bytes memory nestedCall = abi.encodeCall(ISecurityWallet.withdrawAssetToUser, (target, usdc, 1));
        (bool success, bytes memory returndata) = address(this).delegatecall(nestedCall);
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        return returndata;
    }
}

contract SecurityTest is IntegrationBase {
    address private attacker = makeAddr("attacker");
    ReenterExecuteAdapter private reenterExecute;
    ReenterWithdrawAdapter private reenterWithdraw;

    function test_NonOperatorCannotCreateWallet() public {
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, operatorRole));
        vm.prank(attacker);
        factory.createAgentWallet(owner, 3, address(usdc), VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
    }

    function test_NonAdminCannotReplaceRegistryOfActiveWallet() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 depositAmount = 50e6;
        _fundWallet(wallet, address(usdc), depositAmount);

        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, adminRole);
        vm.expectRevert(unauthorizedError);
        vm.prank(attacker);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, borrowRegistry);

        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (depositAmount));
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(erc4626Vault.balanceOf(address(wallet)), depositAmount);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_OwnerAndOperatorCanExecuteButAttackerCannot() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 depositAmount = 100e6;
        _fundWallet(wallet, address(usdc), depositAmount * 3);
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (depositAmount));

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), depositData);

        vm.prank(owner);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, attacker));
        vm.prank(attacker);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);

        assertEq(erc4626Vault.balanceOf(address(wallet)), depositAmount * 2);
        assertEq(usdc.balanceOf(address(wallet)), depositAmount);
    }

    function test_OperatorCannotUseOwnerOnlySelectors() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 amount = 100e6;
        _fundWallet(wallet, address(usdc), amount);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        wallet.blockAdapter(address(erc4626Adapter));

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        vm.prank(operator);
        wallet.withdrawAssetToUser(owner, address(usdc), amount);

        assertEq(usdc.balanceOf(address(wallet)), amount);
        vm.prank(owner);
        wallet.withdrawAssetToUser(owner, address(usdc), amount);
        assertEq(usdc.balanceOf(owner), amount);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_OwnerBlocklistsAdaptersAndTargets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (50e6));

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, attacker));
        vm.prank(attacker);
        wallet.blockAdapter(address(erc4626Adapter));

        vm.prank(owner);
        wallet.blockAdapter(address(erc4626Adapter));
        vm.expectRevert(abi.encodeWithSelector(AdapterIsBlocked.selector, address(erc4626Adapter)));
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);

        vm.prank(owner);
        wallet.unblockAdapter(address(erc4626Adapter));
        vm.prank(owner);
        wallet.blockTarget(address(erc4626Vault));
        vm.expectRevert(abi.encodeWithSelector(TargetIsBlocked.selector, address(erc4626Vault)));
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);

        vm.prank(owner);
        wallet.unblockTarget(address(erc4626Vault));
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 50e6);
    }

    function test_UnregisteringAdapterBlocksExecutionAndReregisteringRestoresIt() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (50e6));

        vaultRegistry.unregisterAdapter(address(erc4626Adapter));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter)));
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);

        vaultRegistry.registerAdapter(address(erc4626Adapter));
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 50e6);
    }

    function test_RegistryPauseBlocksExecutionUntilUnpaused() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (50e6));

        vaultRegistry.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);

        vaultRegistry.unpause();
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 50e6);
    }

    function test_RemovingTargetPreventsExecutionAfterAdapterReregistration() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (50e6));

        vaultRegistry.unregisterAdapter(address(erc4626Adapter));
        vaultRegistry.removeTarget(address(erc4626Vault));
        vaultRegistry.registerAdapter(address(erc4626Adapter));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter)));
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), depositData);
        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
    }

    function test_ZeroDepositAndWithdrawRevertWithExactErrors() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);

        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));

        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
    }

    function test_BatchFailureRevertsAllEarlierOperations() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 500e6);
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(erc4626Adapter);
        targets[0] = address(erc4626Vault);
        targets[1] = address(0);
        datas[0] = abi.encodeCall(erc4626Adapter.deposit, (200e6));
        datas[1] = abi.encodeCall(erc4626Adapter.deposit, (100e6));

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter)));
        vm.prank(operator);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(usdc.balanceOf(address(wallet)), 500e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(erc4626Vault)), 0);
    }

    function test_ReentrantAdapterExecutionRevertsWithoutChangingWalletState() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        _registerReentrantAdapters();

        _executeExpectRevert(wallet, address(reenterExecute), address(reenterExecute), "", abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));

        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
    }

    function test_ReentrantWithdrawalRevertsWithoutChangingWalletState() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 100e6);
        _registerReentrantAdapters();

        _executeExpectRevert(wallet, address(reenterWithdraw), address(reenterWithdraw), "", abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector));

        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(usdc.balanceOf(address(reenterWithdraw)), 0);
    }

    function test_ReentrantBatchFailureRollsBackPriorDeposit() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 200e6);
        _registerReentrantAdapters();
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(reenterExecute);
        targets[0] = address(erc4626Vault);
        targets[1] = address(reenterExecute);
        datas[0] = abi.encodeCall(erc4626Adapter.deposit, (100e6));
        datas[1] = "";

        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)));
        vm.prank(operator);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(usdc.balanceOf(address(wallet)), 200e6);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(erc4626Vault)), 0);
    }

    function _registerReentrantAdapters() private {
        reenterExecute = new ReenterExecuteAdapter();
        reenterWithdraw = new ReenterWithdrawAdapter(address(usdc));
        vaultRegistry.registerAdapter(address(reenterExecute));
        vaultRegistry.setTargetAdapter(address(reenterExecute), address(reenterExecute));
        vaultRegistry.registerAdapter(address(reenterWithdraw));
        vaultRegistry.setTargetAdapter(address(reenterWithdraw), address(reenterWithdraw));
    }
}
