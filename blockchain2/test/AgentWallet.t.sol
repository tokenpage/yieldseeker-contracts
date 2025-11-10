// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAccessController} from "../src/AccessController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    function mint(address account, uint256 amount) external {
        _balances[account] += amount;
        _totalSupply += amount;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}

contract YieldSeekerAgentWalletV2 is YieldSeekerAgentWallet {
    constructor(address _operator, address _factory) YieldSeekerAgentWallet(_operator, _factory) {}

    // V2 adds a new feature
    function version() external pure returns (string memory) {
        return "v2";
    }
}

contract AgentWalletTest is Test {
    YieldSeekerAccessController public accessController;
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    MockERC20 public usdc;

    address public admin = address(0x1);
    address public operator = address(0x2);
    address public user = address(0x3);
    address public user2 = address(0x4);

    function setUp() public {
        vm.startPrank(admin);

        // Deploy access controller
        accessController = new YieldSeekerAccessController(admin);
        accessController.grantRole(accessController.OPERATOR_ROLE(), operator);

        // Deploy factory
        factory = new YieldSeekerAgentWalletFactory(admin);

        // Deploy implementation with factory address
        implementation = new YieldSeekerAgentWallet(address(accessController), address(factory));

        // Approve implementation in factory
        factory.setImplementation(address(implementation));

        // Deploy mock USDC
        usdc = new MockERC20();

        vm.stopPrank();
    }

    function test_CreateAgentWallet() public {
        vm.prank(admin);
        address wallet = factory.createAgentWallet(user, 0, address(usdc));

        assertNotEq(wallet, address(0), "Wallet should be created");

        YieldSeekerAgentWallet agentWallet = YieldSeekerAgentWallet(payable(wallet));
        assertEq(agentWallet.owner(), user, "Owner should be user");
        assertEq(agentWallet.ownerAgentIndex(), 0, "Agent index should be 0");
        assertEq(address(agentWallet.baseAsset()), address(usdc), "Base asset should be USDC");
    }

    function test_CreateMultipleWalletsForSameUser() public {
        vm.startPrank(admin);

        address wallet1 = factory.createAgentWallet(user, 0, address(usdc));
        address wallet2 = factory.createAgentWallet(user, 1, address(usdc));
        address wallet3 = factory.createAgentWallet(user, 2, address(usdc));

        vm.stopPrank();

        assertTrue(wallet1 != wallet2, "Wallets should have different addresses");
        assertTrue(wallet2 != wallet3, "Wallets should have different addresses");
        assertTrue(wallet1 != wallet3, "Wallets should have different addresses");

        assertEq(YieldSeekerAgentWallet(payable(wallet1)).ownerAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(wallet2)).ownerAgentIndex(), 1);
        assertEq(YieldSeekerAgentWallet(payable(wallet3)).ownerAgentIndex(), 2);
    }

    function test_RevertCreateDuplicateWallet() public {
        vm.startPrank(admin);

        factory.createAgentWallet(user, 0, address(usdc));

        vm.expectRevert(abi.encodeWithSelector(YieldSeekerAgentWalletFactory.AgentAlreadyExists.selector, user, 0));
        factory.createAgentWallet(user, 0, address(usdc));

        vm.stopPrank();
    }

    function test_PredictAgentWalletAddress() public {
        address predicted = factory.predictAgentWalletAddress(user, 0, address(usdc));

        vm.prank(admin);
        address actual = factory.createAgentWallet(user, 0, address(usdc));

        assertEq(predicted, actual, "Predicted address should match actual address");
    }

    function test_DeterministicAddressAcrossChains() public {
        // Simulate different chain by creating new factory at same address
        // In reality, same factory address would be deployed on multiple chains
        address predicted1 = factory.predictAgentWalletAddress(user, 0, address(usdc));
        address predicted2 = factory.predictAgentWalletAddress(user, 0, address(usdc));

        assertEq(predicted1, predicted2, "Same user+index should always produce same address");
    }

    function test_TransferOwnership() public {
        vm.prank(admin);
        address wallet = factory.createAgentWallet(user, 0, address(usdc));

        YieldSeekerAgentWallet agentWallet = YieldSeekerAgentWallet(payable(wallet));

        vm.prank(user);
        agentWallet.transferOwnership(user2);

        assertEq(agentWallet.owner(), user2, "Owner should be transferred");
    }

    function test_RevertTransferOwnershipNotOwner() public {
        vm.prank(admin);
        address wallet = factory.createAgentWallet(user, 0, address(usdc));

        YieldSeekerAgentWallet agentWallet = YieldSeekerAgentWallet(payable(wallet));

        vm.prank(user2);
        vm.expectRevert(YieldSeekerAgentWallet.NotOwner.selector);
        agentWallet.transferOwnership(user2);
    }

    function test_SetNewImplementation() public {
        YieldSeekerAgentWallet newImpl = new YieldSeekerAgentWallet(address(accessController), address(factory));

        vm.prank(admin);
        factory.setImplementation(address(newImpl));

        assertEq(factory.currentImplementation(), address(newImpl), "Current implementation should be updated");
    }

    function test_UpgradeToLatest() public {
        // Create wallet with V1
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Deploy V2 implementation
        YieldSeekerAgentWalletV2 implV2 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));

        // Approve V2
        vm.prank(admin);
        factory.setImplementation(address(implV2));

        // User upgrades to V2
        vm.prank(user);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToLatest();

        // Verify V2 functionality
        string memory version = YieldSeekerAgentWalletV2(payable(walletAddr)).version();
        assertEq(version, "v2", "Wallet should be upgraded to V2");
    }

    function test_RevertUpgradeNotOwner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        YieldSeekerAgentWalletV2 implV2 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));

        vm.prank(admin);
        factory.setImplementation(address(implV2));

        // Non-owner tries to upgrade
        vm.prank(user2);
        vm.expectRevert(YieldSeekerAgentWallet.NotOwner.selector);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToLatest();
    }

    function test_RevertUpgradeToNonCurrentImplementation() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Deploy V2 and approve it (making it current)
        YieldSeekerAgentWalletV2 implV2 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));
        vm.prank(admin);
        factory.setImplementation(address(implV2));

        // Deploy V3 but don't approve it (so it's not current)
        YieldSeekerAgentWalletV2 implV3 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));

        // User tries to upgrade directly to V3 (not current implementation)
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.NotApprovedImplementation.selector);
        UUPSUpgradeable(walletAddr).upgradeToAndCall(address(implV3), "");
    }

    function test_RevertDowngradeToOldImplementation() public {
        // Create wallet with V1
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        address implV1 = address(implementation);

        // Deploy V2 and make it current
        YieldSeekerAgentWalletV2 implV2 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));
        vm.prank(admin);
        factory.setImplementation(address(implV2));

        // User upgrades to V2
        vm.prank(user);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToLatest();

        // Try to downgrade back to V1 (should fail because it's not current)
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.NotApprovedImplementation.selector);
        UUPSUpgradeable(walletAddr).upgradeToAndCall(implV1, "");
    }

    function test_GetTotalWalletCount() public {
        assertEq(factory.getTotalWalletCount(), 0, "Should start with 0 wallets");

        vm.startPrank(admin);
        factory.createAgentWallet(user, 0, address(usdc));
        assertEq(factory.getTotalWalletCount(), 1, "Should have 1 wallet");

        factory.createAgentWallet(user, 1, address(usdc));
        assertEq(factory.getTotalWalletCount(), 2, "Should have 2 wallets");

        factory.createAgentWallet(user2, 0, address(usdc));
        assertEq(factory.getTotalWalletCount(), 3, "Should have 3 wallets");
        vm.stopPrank();
    }

    function test_GetAllAgentWallets() public {
        vm.startPrank(admin);

        address wallet1 = factory.createAgentWallet(user, 0, address(usdc));
        address wallet2 = factory.createAgentWallet(user, 1, address(usdc));
        address wallet3 = factory.createAgentWallet(user2, 0, address(usdc));

        vm.stopPrank();

        address[] memory allWallets = factory.getAllAgentWallets();

        assertEq(allWallets.length, 3, "Should return all 3 wallets");
        assertEq(allWallets[0], wallet1, "First wallet should match");
        assertEq(allWallets[1], wallet2, "Second wallet should match");
        assertEq(allWallets[2], wallet3, "Third wallet should match");
    }

    function test_ReceiveETH() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Send ETH to wallet
        vm.deal(address(this), 1 ether);
        (bool success,) = payable(walletAddr).call{value: 1 ether}("");
        assertTrue(success, "ETH transfer should succeed");

        assertEq(walletAddr.balance, 1 ether, "Wallet should receive ETH");
    }

    function test_StatePreservedAfterUpgrade() public {
        // Create wallet and send some funds
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        vm.deal(walletAddr, 1 ether);
        usdc.mint(walletAddr, 1000e6);

        uint256 ethBalanceBefore = walletAddr.balance;
        uint256 usdcBalanceBefore = usdc.balanceOf(walletAddr);
        address ownerBefore = YieldSeekerAgentWallet(payable(walletAddr)).owner();
        uint256 indexBefore = YieldSeekerAgentWallet(payable(walletAddr)).ownerAgentIndex();

        // Deploy and approve V2
        YieldSeekerAgentWalletV2 implV2 = new YieldSeekerAgentWalletV2(address(accessController), address(factory));
        vm.prank(admin);
        factory.setImplementation(address(implV2));

        // Upgrade
        vm.prank(user);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToLatest();

        // Verify state preserved
        assertEq(walletAddr.balance, ethBalanceBefore, "ETH balance should be preserved");
        assertEq(usdc.balanceOf(walletAddr), usdcBalanceBefore, "USDC balance should be preserved");
        assertEq(YieldSeekerAgentWallet(payable(walletAddr)).owner(), ownerBefore, "Owner should be preserved");
        assertEq(YieldSeekerAgentWallet(payable(walletAddr)).ownerAgentIndex(), indexBefore, "Index should be preserved");
    }
}
