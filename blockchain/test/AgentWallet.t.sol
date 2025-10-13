// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {YieldSeekerAccessController} from "../src/AccessController.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockVaultProvider} from "./MockVaultProvider.sol";

/**
 * @title AgentWalletTest
 * @notice Comprehensive test suite for AgentWallet functionality
 */
contract AgentWalletTest is Test {
    YieldSeekerAccessController public operator;
    YieldSeekerAgentWallet public agentWalletImpl;
    YieldSeekerAgentWalletFactory public factory;
    MockERC20 public mockUSDC;
    MockVaultProvider public mockVaultProvider;

    address public admin = address(0x1);
    address public backendOperator = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public attacker = address(0x5);

    address public mockVault1 = address(0x100);
    address public mockVault2 = address(0x101);

    YieldSeekerAgentWallet public agentWallet;

    event DepositedToVault(address indexed vault, uint256 amount, uint256 shares);
    event WithdrewFromVault(address indexed vault, uint256 shares, uint256 amount);
    event Rebalanced(address indexed operator, uint256 withdrawals, uint256 deposits);
    event WithdrewBaseAssetToUser(address indexed owner, address indexed recipient, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);

    function setUp() public {
        // Deploy core contracts
        vm.startPrank(admin);

        mockUSDC = new MockERC20("USDC", "USDC");
        operator = new YieldSeekerAccessController(admin);
        agentWalletImpl = new YieldSeekerAgentWallet(address(operator));
        factory = new YieldSeekerAgentWalletFactory(admin, address(agentWalletImpl));
        mockVaultProvider = new MockVaultProvider();

        // Add backend operator
        operator.grantRole(operator.OPERATOR_ROLE(), backendOperator);

        // Approve vault provider
        operator.approveVaultProvider(address(mockVaultProvider));

        // Register vaults
        operator.registerVault(mockVault1, address(mockVaultProvider));
        operator.registerVault(mockVault2, address(mockVaultProvider));

        vm.stopPrank();

        // Create agent wallet for user1
        vm.prank(admin);
        address agentAddress = factory.createAgentWallet(user1, 0, address(mockUSDC));
        agentWallet = YieldSeekerAgentWallet(payable(agentAddress));

        // Give user1 some USDC
        mockUSDC.mint(user1, 10_000e18);
    }

    // ============ INITIALIZATION TESTS ============

    function testCreateAgentWallet() public {
        vm.prank(admin);
        address newAgent = factory.createAgentWallet(user2, 0, address(mockUSDC));

        YieldSeekerAgentWallet agent = YieldSeekerAgentWallet(payable(newAgent));
        assertEq(agent.owner(), user2);
        assertEq(agent.ownerAgentIndex(), 0);
        assertEq(address(agent.baseAsset()), address(mockUSDC));
    }

    function testCannotReinitialize() public {
        vm.expectRevert(YieldSeekerAgentWallet.AlreadyInitialized.selector);
        agentWallet.initialize(user2, 1, address(mockUSDC));
    }

    function testCreateMultipleAgentsPerUser() public {
        vm.startPrank(admin);
        address agent1 = factory.createAgentWallet(user2, 0, address(mockUSDC));
        address agent2 = factory.createAgentWallet(user2, 1, address(mockUSDC));
        vm.stopPrank();

        assertEq(factory.userWallets(user2, 0), agent1);
        assertEq(factory.userWallets(user2, 1), agent2);
        assertTrue(agent1 != agent2);

        assertEq(YieldSeekerAgentWallet(payable(agent1)).ownerAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(agent2)).ownerAgentIndex(), 1);
    }

    // ============ VAULT DEPOSIT TESTS ============

    function testDepositToVault() public {
        // User deposits USDC to agent wallet
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        // Backend operator deposits to vault
        vm.prank(backendOperator);
        vm.expectEmit(true, false, false, true);
        emit DepositedToVault(mockVault1, 1000e18, 1000e18);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Verify shares were minted
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 1000e18);
    }

    function testDepositToMultipleVaults() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 2000e18);

        vm.startPrank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);
        agentWallet.depositToVault(mockVault2, 1000e18);
        vm.stopPrank();

        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 1000e18);
        assertEq(mockVaultProvider.getShareCount(mockVault2, address(agentWallet)), 1000e18);
    }

    function testDepositRevertsWithInsufficientBalance() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 500e18);

        vm.prank(backendOperator);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientBalance.selector);
        agentWallet.depositToVault(mockVault1, 1000e18);
    }

    function testDepositRevertsIfNotOperator() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        vm.prank(attacker);
        vm.expectRevert(YieldSeekerAgentWallet.NotOperator.selector);
        agentWallet.depositToVault(mockVault1, 1000e18);
    }

    function testDepositRevertsIfSystemPaused() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        vm.prank(admin);
        operator.pause();

        vm.prank(backendOperator);
        vm.expectRevert(YieldSeekerAgentWallet.SystemPaused.selector);
        agentWallet.depositToVault(mockVault1, 1000e18);
    }

    function testDepositRevertsWithUnregisteredVault() public {
        address unregisteredVault = address(0x999);

        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        vm.prank(backendOperator);
        vm.expectRevert(); // VaultRegistry will revert with VaultNotRegistered
        agentWallet.depositToVault(unregisteredVault, 1000e18);
    }

    // ============ VAULT WITHDRAWAL TESTS ============

    function testWithdrawFromVault() public {
        // Setup: Deposit first
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Withdraw
        vm.prank(backendOperator);
        vm.expectEmit(true, false, false, true);
        emit WithdrewFromVault(mockVault1, 500e18, 500e18);
        agentWallet.withdrawFromVault(mockVault1, 500e18);

        // Verify shares were burned and USDC returned
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 500e18);
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 500e18);
    }

    function testWithdrawAllFromVault() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        vm.prank(backendOperator);
        agentWallet.withdrawFromVault(mockVault1, 1000e18);

        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 0);
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 1000e18);
    }

    function testWithdrawRevertsWithInsufficientShares() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 500e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 500e18);

        vm.prank(backendOperator);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientWithdrawableShares.selector);
        agentWallet.withdrawFromVault(mockVault1, 1000e18);
    }

    function testWithdrawRevertsWithWithdrawalLimit() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Simulate withdrawal limit (only 500 withdrawable)
        mockVaultProvider.setWithdrawableShares(mockVault1, address(agentWallet), 500e18);

        vm.prank(backendOperator);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientWithdrawableShares.selector);
        agentWallet.withdrawFromVault(mockVault1, 1000e18);
    }

    function testWithdrawRevertsIfNotOperator() public {
        vm.prank(user1);
        vm.expectRevert(YieldSeekerAgentWallet.NotOperator.selector);
        agentWallet.withdrawFromVault(mockVault1, 100e18);
    }

    // ============ REBALANCE TESTS ============

    function testRebalanceSimple() public {
        // Setup: Deposit to vault1
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 2000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 2000e18);

        // Rebalance: Withdraw 50% from vault1, deposit 100% to vault2
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](1);
        withdrawals[0] = YieldSeekerAgentWallet.WithdrawOperation({vault: mockVault1, percentageBps: 5000}); // 50%

        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](1);
        deposits[0] = YieldSeekerAgentWallet.DepositOperation({vault: mockVault2, percentageBps: 10_000}); // 100%

        vm.prank(backendOperator);
        vm.expectEmit(true, false, false, true);
        emit Rebalanced(backendOperator, 1, 1);
        agentWallet.rebalance(withdrawals, deposits);

        // Verify: 50% in vault1, 50% in vault2
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 1000e18);
        assertEq(mockVaultProvider.getShareCount(mockVault2, address(agentWallet)), 1000e18);
    }

    function testRebalanceMultipleVaults() public {
        // Setup: Deposit to vault1
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Rebalance: Withdraw 100% from vault1, split 60/40 between vault1 and vault2
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](1);
        withdrawals[0] = YieldSeekerAgentWallet.WithdrawOperation({vault: mockVault1, percentageBps: 10_000});

        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](2);
        deposits[0] = YieldSeekerAgentWallet.DepositOperation({vault: mockVault1, percentageBps: 6000}); // 60%
        deposits[1] = YieldSeekerAgentWallet.DepositOperation({vault: mockVault2, percentageBps: 4000}); // 40%

        vm.prank(backendOperator);
        agentWallet.rebalance(withdrawals, deposits);

        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 600e18);
        assertEq(mockVaultProvider.getShareCount(mockVault2, address(agentWallet)), 400e18);
    }

    function testRebalanceWithZeroPercentage() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Rebalance with 0% - should be skipped
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](1);
        withdrawals[0] = YieldSeekerAgentWallet.WithdrawOperation({vault: mockVault1, percentageBps: 0});

        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](0);

        vm.prank(backendOperator);
        agentWallet.rebalance(withdrawals, deposits);

        // Nothing should change
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 1000e18);
    }

    function testRebalanceRevertsWithInvalidPercentage() public {
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](1);
        withdrawals[0] = YieldSeekerAgentWallet.WithdrawOperation({vault: mockVault1, percentageBps: 10_001}); // > 100%

        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](0);

        vm.prank(backendOperator);
        vm.expectRevert(YieldSeekerAgentWallet.InvalidPercentage.selector);
        agentWallet.rebalance(withdrawals, deposits);
    }

    function testRebalanceHandlesWithdrawalLimits() public {
        // Setup: Deposit 1000 to vault1
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Set withdrawal limit to 500
        mockVaultProvider.setWithdrawableShares(mockVault1, address(agentWallet), 500e18);

        // Try to rebalance 100% (should only withdraw 500)
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](1);
        withdrawals[0] = YieldSeekerAgentWallet.WithdrawOperation({vault: mockVault1, percentageBps: 10_000});

        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](1);
        deposits[0] = YieldSeekerAgentWallet.DepositOperation({vault: mockVault2, percentageBps: 10_000});

        vm.prank(backendOperator);
        agentWallet.rebalance(withdrawals, deposits);

        // Should have withdrawn only 500, deposited 500 to vault2
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 500e18); // 500 remaining
        assertEq(mockVaultProvider.getShareCount(mockVault2, address(agentWallet)), 500e18); // 500 deposited
    }

    function testRebalanceRevertsIfNotOperator() public {
        YieldSeekerAgentWallet.WithdrawOperation[] memory withdrawals = new YieldSeekerAgentWallet.WithdrawOperation[](0);
        YieldSeekerAgentWallet.DepositOperation[] memory deposits = new YieldSeekerAgentWallet.DepositOperation[](0);

        vm.prank(attacker);
        vm.expectRevert(YieldSeekerAgentWallet.NotOperator.selector);
        agentWallet.rebalance(withdrawals, deposits);
    }

    // ============ USER WITHDRAWAL TESTS ============

    function testUserWithdrawBaseAsset() public {
        // Give agent wallet some USDC
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        // User withdraws to themselves
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit WithdrewBaseAssetToUser(user1, user1, 500e18);
        agentWallet.withdrawBaseAssetToUser(user1, 500e18);

        assertEq(mockUSDC.balanceOf(user1), 9500e18); // 10000 - 1000 + 500
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 500e18);
    }

    function testUserWithdrawBaseAssetToDifferentAddress() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        // User withdraws to user2
        vm.prank(user1);
        agentWallet.withdrawBaseAssetToUser(user2, 500e18);

        assertEq(mockUSDC.balanceOf(user2), 500e18);
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 500e18);
    }

    function testUserWithdrawAllBaseAsset() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);

        vm.prank(user1);
        agentWallet.withdrawAllBaseAssetToUser(user1);

        assertEq(mockUSDC.balanceOf(user1), 10_000e18); // Back to original
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 0);
    }

    function testUserWithdrawBaseAssetRevertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(YieldSeekerAgentWallet.NotOwner.selector);
        agentWallet.withdrawBaseAssetToUser(attacker, 100e18);
    }

    function testUserWithdrawBaseAssetRevertsWithInsufficientBalance() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 500e18);

        vm.prank(user1);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientBalance.selector);
        agentWallet.withdrawBaseAssetToUser(user1, 1000e18);
    }

    function testUserWithdrawBaseAssetRevertsWithZeroAddress() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 500e18);

        vm.prank(user1);
        vm.expectRevert(YieldSeekerAgentWallet.InvalidAddress.selector);
        agentWallet.withdrawBaseAssetToUser(address(0), 100e18);
    }

    // ============ ETH WITHDRAWAL TESTS ============

    function testUserWithdrawEth() public {
        // Send ETH to agent wallet
        vm.deal(address(agentWallet), 2 ether);

        uint256 user1BalanceBefore = user1.balance;

        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit WithdrewEthToUser(user1, user1, 1 ether);
        agentWallet.withdrawEthToUser(user1, 1 ether);

        assertEq(user1.balance, user1BalanceBefore + 1 ether);
        assertEq(address(agentWallet).balance, 1 ether);
    }

    function testUserWithdrawAllEth() public {
        vm.deal(address(agentWallet), 2 ether);

        uint256 user1BalanceBefore = user1.balance;

        vm.prank(user1);
        agentWallet.withdrawAllEthToUser(user1);

        assertEq(user1.balance, user1BalanceBefore + 2 ether);
        assertEq(address(agentWallet).balance, 0);
    }

    function testUserWithdrawEthRevertsIfNotOwner() public {
        vm.deal(address(agentWallet), 1 ether);

        vm.prank(attacker);
        vm.expectRevert(YieldSeekerAgentWallet.NotOwner.selector);
        agentWallet.withdrawEthToUser(attacker, 1 ether);
    }

    function testUserWithdrawEthRevertsWithInsufficientBalance() public {
        vm.deal(address(agentWallet), 0.5 ether);

        vm.prank(user1);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientBalance.selector);
        agentWallet.withdrawEthToUser(user1, 1 ether);
    }

    function testReceiveEth() public {
        // Agent wallet can receive ETH
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        (bool success,) = address(agentWallet).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(agentWallet).balance, 1 ether);
    }

    // ============ EMERGENCY WITHDRAWAL TESTS ============

    function testUserEmergencyWithdrawFromAllVaults() public {
        // Setup: Deposit to multiple vaults
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 2000e18);
        vm.startPrank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);
        agentWallet.depositToVault(mockVault2, 1000e18);
        vm.stopPrank();

        // Emergency withdraw
        address[] memory vaults = new address[](2);
        vaults[0] = mockVault1;
        vaults[1] = mockVault2;

        vm.prank(user1);
        agentWallet.withdrawFromAllVaults(vaults);

        // Verify all withdrawn
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 0);
        assertEq(mockVaultProvider.getShareCount(mockVault2, address(agentWallet)), 0);
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 2000e18);
    }

    function testEmergencyWithdrawSkipsVaultsWithNoShares() public {
        // Only deposit to vault1
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Try to withdraw from both (vault2 has no shares)
        address[] memory vaults = new address[](2);
        vaults[0] = mockVault1;
        vaults[1] = mockVault2;

        vm.prank(user1);
        agentWallet.withdrawFromAllVaults(vaults); // Should not revert

        assertEq(mockUSDC.balanceOf(address(agentWallet)), 1000e18);
    }

    function testEmergencyWithdrawRespectsWithdrawalLimits() public {
        vm.prank(user1);
        mockUSDC.transfer(address(agentWallet), 1000e18);
        vm.prank(backendOperator);
        agentWallet.depositToVault(mockVault1, 1000e18);

        // Set withdrawal limit
        mockVaultProvider.setWithdrawableShares(mockVault1, address(agentWallet), 500e18);

        address[] memory vaults = new address[](1);
        vaults[0] = mockVault1;

        vm.prank(user1);
        agentWallet.withdrawFromAllVaults(vaults);

        // Should only withdraw 500
        assertEq(mockVaultProvider.getShareCount(mockVault1, address(agentWallet)), 500e18);
        assertEq(mockUSDC.balanceOf(address(agentWallet)), 500e18);
    }

    function testEmergencyWithdrawRevertsIfNotOwner() public {
        address[] memory vaults = new address[](0);

        vm.prank(attacker);
        vm.expectRevert(YieldSeekerAgentWallet.NotOwner.selector);
        agentWallet.withdrawFromAllVaults(vaults);
    }

    // ============ ACCESS CONTROL TESTS ============

    function testPauseUnpause() public {
        vm.startPrank(admin);
        operator.pause();
        assertTrue(operator.paused());
        operator.unpause();
        assertFalse(operator.paused());
        vm.stopPrank();
    }

    function testOnlyAdminCanPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        operator.pause();
    }

    function testAddRemoveOperator() public {
        address newOperator = address(0x6);

        vm.startPrank(admin);
        operator.grantRole(operator.OPERATOR_ROLE(), newOperator);
        assertTrue(operator.hasRole(operator.OPERATOR_ROLE(), newOperator));

        operator.revokeRole(operator.OPERATOR_ROLE(), newOperator);
        assertFalse(operator.hasRole(operator.OPERATOR_ROLE(), newOperator));
        vm.stopPrank();
    }

    function testVaultRegistryApproval() public {
        address mockVault = address(0x200);
        address newMockProvider = address(0x201);

        vm.startPrank(admin);
        operator.approveVaultProvider(newMockProvider);
        operator.registerVault(mockVault, newMockProvider);

        address provider = operator.getVaultProvider(mockVault);
        assertEq(provider, newMockProvider);
        vm.stopPrank();
    }

    function testSwapRegistryApproval() public {
        address mockSwapProvider = address(0x300);

        vm.startPrank(admin);
        operator.approveSwapProvider(mockSwapProvider);
        assertTrue(operator.isSwapApproved(mockSwapProvider));

        operator.removeSwapProvider(mockSwapProvider);
        assertFalse(operator.isSwapApproved(mockSwapProvider));
        vm.stopPrank();
    }
}
