pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AdapterExecutionFailed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IAWKAdapter} from "../../src/agentwalletkit/IAWKAdapter.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface ISecurityWallet {
    function executeViaAdapter(address adapter, address target, bytes calldata data) external returns (bytes memory);
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

contract SecurityTest is IntegrationBase {
    address private attacker = makeAddr("attacker");
    ReenterExecuteAdapter private reenterExecute;

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
        vaultRegistry.registerAdapter(address(reenterExecute));
        vaultRegistry.setTargetAdapter(address(reenterExecute), address(reenterExecute));
    }
}
