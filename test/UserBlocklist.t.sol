// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerErrors} from "../src/Errors.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// Mock ERC4626 Vault for testing
contract MockVault is ERC20, IERC4626 {
    IERC20 private immutable _ASSET;

    constructor(IERC20 asset_, string memory name, string memory symbol) ERC20(name, symbol) {
        _ASSET = asset_;
    }

    function asset() public view override returns (address) {
        return address(_ASSET);
    }

    function totalAssets() public view override returns (uint256) {
        return _ASSET.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * totalAssets() + supply - 1) / supply;
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply + totalAssets() - 1) / totalAssets();
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = previewDeposit(assets);
        require(_ASSET.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        uint256 assets = previewMint(shares);
        require(_ASSET.transferFrom(msg.sender, address(this), assets), "transfer failed");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        require(_ASSET.transfer(receiver, assets), "transfer failed");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        uint256 assets = previewRedeem(shares);
        _burn(owner, shares);
        require(_ASSET.transfer(receiver, assets), "transfer failed");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }
}

/**
 * @title UserBlocklistTest
 * @notice Tests for user-level adapter and target blocklist functionality
 * @dev Tests user sovereignty features that allow wallet owners to block specific
 *      adapters or targets even when they are globally approved
 */
contract UserBlocklistTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    AgentWallet walletImpl;
    YieldSeekerERC4626Adapter erc4626Adapter;

    MockUSDC usdc;
    MockVault vault1;
    MockVault vault2;

    address admin = address(0x1);
    address emergencyAdmin = address(0x2);
    address feeCollector = address(0x3);
    address agentOperator = address(0x4);
    address user = address(0x100);

    AgentWallet userWallet;

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockUSDC();
        vault1 = new MockVault(IERC20(address(usdc)), "Vault1", "V1");
        vault2 = new MockVault(IERC20(address(usdc)), "Vault2", "V2");

        // Deploy core contracts
        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin);
        factory = new AgentWalletFactory(admin, agentOperator);

        // Deploy wallet implementation
        walletImpl = new AgentWallet(address(factory));

        // Set factory configuration
        factory.setAgentWalletImplementation(walletImpl);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);

        // Deploy and register adapter
        erc4626Adapter = new YieldSeekerERC4626Adapter();
        registry.registerAdapter(address(erc4626Adapter));
        registry.setTargetAdapter(address(vault1), address(erc4626Adapter));
        registry.setTargetAdapter(address(vault2), address(erc4626Adapter));
        vm.stopPrank();

        // Create user wallet
        vm.prank(agentOperator);
        userWallet = AgentWallet(payable(factory.createAgentWallet(user, 0, address(usdc))));

        // Fund user wallet
        usdc.mint(address(userWallet), 1000e6);
    }

    /**
     * @notice Test that owner can block an adapter
     */
    function test_OwnerCanBlockAdapter() public {
        vm.prank(user);
        userWallet.blockAdapter(address(erc4626Adapter));

        assertTrue(userWallet.isAdapterBlocked(address(erc4626Adapter)));
    }

    /**
     * @notice Test that owner can unblock an adapter
     */
    function test_OwnerCanUnblockAdapter() public {
        vm.startPrank(user);
        userWallet.blockAdapter(address(erc4626Adapter));
        assertTrue(userWallet.isAdapterBlocked(address(erc4626Adapter)));

        userWallet.unblockAdapter(address(erc4626Adapter));
        assertFalse(userWallet.isAdapterBlocked(address(erc4626Adapter)));
        vm.stopPrank();
    }

    /**
     * @notice Test that owner can block a target
     */
    function test_OwnerCanBlockTarget() public {
        vm.prank(user);
        userWallet.blockTarget(address(vault1));

        assertTrue(userWallet.isTargetBlocked(address(vault1)));
    }

    /**
     * @notice Test that owner can unblock a target
     */
    function test_OwnerCanUnblockTarget() public {
        vm.startPrank(user);
        userWallet.blockTarget(address(vault1));
        assertTrue(userWallet.isTargetBlocked(address(vault1)));

        userWallet.unblockTarget(address(vault1));
        assertFalse(userWallet.isTargetBlocked(address(vault1)));
        vm.stopPrank();
    }

    /**
     * @notice Test that non-owner cannot block adapter
     */
    function test_RevertWhen_NonOwnerBlocksAdapter() public {
        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, agentOperator));
        userWallet.blockAdapter(address(erc4626Adapter));
    }

    /**
     * @notice Test that non-owner cannot block target
     */
    function test_RevertWhen_NonOwnerBlocksTarget() public {
        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, agentOperator));
        userWallet.blockTarget(address(vault1));
    }

    /**
     * @notice Test that executeViaAdapter reverts when adapter is blocked
     */
    function test_RevertWhen_ExecutingBlockedAdapter() public {
        // Block the adapter
        vm.prank(user);
        userWallet.blockAdapter(address(erc4626Adapter));

        // Try to execute via blocked adapter
        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);

        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.AdapterBlocked.selector, address(erc4626Adapter)));
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);
    }

    /**
     * @notice Test that executeViaAdapter reverts when target is blocked
     */
    function test_RevertWhen_ExecutingBlockedTarget() public {
        // Block the target
        vm.prank(user);
        userWallet.blockTarget(address(vault1));

        // Try to execute with blocked target
        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);

        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.TargetBlocked.selector, address(vault1)));
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);
    }

    /**
     * @notice Test that user can block specific vault while keeping others accessible
     */
    function test_SelectiveTargetBlocking() public {
        // Block vault1 but not vault2
        vm.prank(user);
        userWallet.blockTarget(address(vault1));

        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);

        // vault1 should be blocked
        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.TargetBlocked.selector, address(vault1)));
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);

        // vault2 should still work
        vm.prank(agentOperator);
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault2), depositData);

        // Verify deposit to vault2 succeeded
        assertGt(vault2.balanceOf(address(userWallet)), 0);
    }

    /**
     * @notice Test that executeViaAdapter succeeds after unblocking
     */
    function test_ExecuteSucceedsAfterUnblocking() public {
        // Block and then unblock
        vm.startPrank(user);
        userWallet.blockAdapter(address(erc4626Adapter));
        userWallet.unblockAdapter(address(erc4626Adapter));
        vm.stopPrank();

        // Should now work
        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);
        vm.prank(agentOperator);
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);

        assertGt(vault1.balanceOf(address(userWallet)), 0);
    }

    /**
     * @notice Test that blocklist checks happen before registry checks
     */
    function test_BlocklistChecksBeforeRegistry() public {
        // Block the registered adapter
        vm.prank(user);
        userWallet.blockAdapter(address(erc4626Adapter));

        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);

        // Should fail with AdapterBlocked, not AdapterNotRegistered
        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.AdapterBlocked.selector, address(erc4626Adapter)));
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);
    }

    /**
     * @notice Test events are emitted when blocking/unblocking
     */
    function test_EventsEmitted() public {
        vm.startPrank(user);

        vm.expectEmit(true, false, false, false);
        emit AgentWallet.AdapterBlocked(address(erc4626Adapter));
        userWallet.blockAdapter(address(erc4626Adapter));

        vm.expectEmit(true, false, false, false);
        emit AgentWallet.AdapterUnblocked(address(erc4626Adapter));
        userWallet.unblockAdapter(address(erc4626Adapter));

        vm.expectEmit(true, false, false, false);
        emit AgentWallet.TargetBlocked(address(vault1));
        userWallet.blockTarget(address(vault1));

        vm.expectEmit(true, false, false, false);
        emit AgentWallet.TargetUnblocked(address(vault1));
        userWallet.unblockTarget(address(vault1));

        vm.stopPrank();
    }

    /**
     * @notice Test that user can block adapter even when globally approved
     * @dev This tests the sovereignty principle: users don't have to trust admin decisions
     */
    function test_UserSovereigntyOverGlobalApproval() public {
        // Adapter is globally approved (set in setUp)
        assertEq(registry.getTargetAdapter(address(vault1)), address(erc4626Adapter));

        // User decides they don't trust it and blocks it
        vm.prank(user);
        userWallet.blockAdapter(address(erc4626Adapter));

        // Even though globally approved, user's blocklist takes precedence
        bytes memory depositData = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);
        vm.prank(agentOperator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.AdapterBlocked.selector, address(erc4626Adapter)));
        userWallet.executeViaAdapter(address(erc4626Adapter), address(vault1), depositData);
    }
}
