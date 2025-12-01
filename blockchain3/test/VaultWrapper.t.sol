// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {ERC4626VaultWrapper} from "../src/vaults/ERC4626VaultWrapper.sol";
import {AaveV3VaultWrapper} from "../src/vaults/AaveV3VaultWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault, MockAaveV3Pool, MockAToken} from "./mocks/MockVaults.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract VaultWrapperTest is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    ERC4626VaultWrapper public erc4626Wrapper;
    AaveV3VaultWrapper public aaveWrapper;
    MockERC20 public usdc;
    MockERC4626Vault public yearnVault;
    MockAaveV3Pool public aavePool;
    MockAToken public aUsdc;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public operator = address(0x3);

    function setUp() public {
        vm.startPrank(admin);

        // Deploy core infrastructure
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);

        // Set default executor (Router will be auto-installed on new wallets)
        factory.setDefaultExecutor(address(router));

        // Deploy mock tokens and vaults
        usdc = new MockERC20("USDC", "USDC");
        yearnVault = new MockERC4626Vault(address(usdc), "Yearn USDC", "yvUSDC");
        aavePool = new MockAaveV3Pool();
        aUsdc = new MockAToken(address(usdc), "Aave USDC", "aUSDC");
        aUsdc.setPool(address(aavePool));
        aavePool.setAToken(address(usdc), address(aUsdc));

        // Deploy wrappers (admin deploys and owns them)
        erc4626Wrapper = new ERC4626VaultWrapper(admin);
        erc4626Wrapper.addVault(address(yearnVault));

        aaveWrapper = new AaveV3VaultWrapper(address(aavePool), admin);
        aaveWrapper.addAsset(address(usdc), address(aUsdc));

        // Fund the Aave pool for withdrawals
        usdc.mint(address(aavePool), 1_000_000e6);

        // Configure policies for wrappers
        policy.addPolicy(address(erc4626Wrapper), erc4626Wrapper.DEPOSIT_SELECTOR(), address(erc4626Wrapper));
        policy.addPolicy(address(erc4626Wrapper), erc4626Wrapper.WITHDRAW_SELECTOR(), address(erc4626Wrapper));
        policy.addPolicy(address(aaveWrapper), aaveWrapper.DEPOSIT_SELECTOR(), address(aaveWrapper));
        policy.addPolicy(address(aaveWrapper), aaveWrapper.WITHDRAW_SELECTOR(), address(aaveWrapper));

        // Allow ERC20 approve calls (address(1) = allow without validation)
        policy.addPolicy(address(usdc), IERC20.approve.selector, address(1));

        vm.stopPrank();
    }

    // ============ ERC4626 Wrapper Tests ============

    function test_ERC4626_Deposit() public {
        // Create wallet (Router is auto-installed)
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Fund wallet with USDC
        usdc.mint(walletAddr, 1000e6);

        // Approve wrapper via router (operator action)
        vm.prank(operator);
        router.executeAction(walletAddr, address(usdc), 0, abi.encodeCall(IERC20.approve, (address(erc4626Wrapper), type(uint256).max)));

        // Execute deposit via router
        bytes memory depositData = abi.encodeWithSelector(erc4626Wrapper.DEPOSIT_SELECTOR(), address(yearnVault), 500e6);

        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);

        // Verify results
        assertEq(usdc.balanceOf(walletAddr), 500e6, "Wallet should have 500 USDC remaining");
        assertEq(yearnVault.balanceOf(walletAddr), 500e6, "Wallet should have 500 vault shares");
    }

    function test_ERC4626_Withdraw() public {
        // Setup: create wallet, deposit first
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Also allow approving vault shares
        vm.prank(admin);
        policy.addPolicy(address(yearnVault), IERC20.approve.selector, address(1));

        usdc.mint(walletAddr, 1000e6);

        vm.startPrank(operator);

        // Approve wrapper for USDC via router
        router.executeAction(walletAddr, address(usdc), 0, abi.encodeCall(IERC20.approve, (address(erc4626Wrapper), type(uint256).max)));

        // Deposit
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(erc4626Wrapper.DEPOSIT_SELECTOR(), address(yearnVault), 1000e6));

        assertEq(yearnVault.balanceOf(walletAddr), 1000e6, "Should have shares after deposit");

        // Approve wrapper for vault shares via router
        router.executeAction(walletAddr, address(yearnVault), 0, abi.encodeCall(IERC20.approve, (address(erc4626Wrapper), type(uint256).max)));

        // Withdraw
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(erc4626Wrapper.WITHDRAW_SELECTOR(), address(yearnVault), 500e6));

        vm.stopPrank();

        assertEq(usdc.balanceOf(walletAddr), 500e6, "Should have USDC back");
        assertEq(yearnVault.balanceOf(walletAddr), 500e6, "Should have remaining shares");
    }

    function test_ERC4626_BlockedVault() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Create an unauthorized vault
        MockERC4626Vault unauthorizedVault = new MockERC4626Vault(address(usdc), "Bad Vault", "BAD");

        usdc.mint(walletAddr, 1000e6);

        bytes memory depositData = abi.encodeWithSelector(
            erc4626Wrapper.DEPOSIT_SELECTOR(),
            address(unauthorizedVault), // Not allowed!
            500e6
        );

        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
    }

    // ============ Aave V3 Wrapper Tests ============

    function test_AaveV3_Deposit() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        usdc.mint(walletAddr, 1000e6);

        // Approve wrapper for USDC via router
        vm.prank(operator);
        router.executeAction(walletAddr, address(usdc), 0, abi.encodeCall(IERC20.approve, (address(aaveWrapper), type(uint256).max)));

        bytes memory depositData = abi.encodeWithSelector(aaveWrapper.DEPOSIT_SELECTOR(), address(usdc), 500e6);

        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, depositData);

        assertEq(usdc.balanceOf(walletAddr), 500e6, "Wallet should have 500 USDC remaining");
        assertEq(aUsdc.balanceOf(walletAddr), 500e6, "Wallet should have 500 aUSDC");
    }

    function test_AaveV3_Withdraw() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Also allow approving aTokens
        vm.prank(admin);
        policy.addPolicy(address(aUsdc), IERC20.approve.selector, address(1));

        usdc.mint(walletAddr, 1000e6);

        vm.startPrank(operator);

        // Approve wrapper for USDC via router
        router.executeAction(walletAddr, address(usdc), 0, abi.encodeCall(IERC20.approve, (address(aaveWrapper), type(uint256).max)));

        // Deposit
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(aaveWrapper.DEPOSIT_SELECTOR(), address(usdc), 1000e6));

        assertEq(aUsdc.balanceOf(walletAddr), 1000e6, "Should have aTokens after deposit");

        // Approve wrapper for aTokens via router
        router.executeAction(walletAddr, address(aUsdc), 0, abi.encodeCall(IERC20.approve, (address(aaveWrapper), type(uint256).max)));

        // Withdraw
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(aaveWrapper.WITHDRAW_SELECTOR(), address(usdc), 500e6));

        vm.stopPrank();

        assertEq(usdc.balanceOf(walletAddr), 500e6, "Should have USDC back");
        assertEq(aUsdc.balanceOf(walletAddr), 500e6, "Should have remaining aTokens");
    }

    function test_AaveV3_BlockedAsset() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Create an unauthorized asset
        MockERC20 unauthorizedToken = new MockERC20("BAD", "BAD");
        unauthorizedToken.mint(walletAddr, 1000e6);

        bytes memory depositData = abi.encodeWithSelector(
            aaveWrapper.DEPOSIT_SELECTOR(),
            address(unauthorizedToken), // Not allowed!
            500e6
        );

        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(aaveWrapper), 0, depositData);
    }

    // ============ Asset Mismatch Tests ============

    function test_ERC4626_AssetMismatch() public {
        // Create a wallet with USDC as base asset
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Create a vault with a different asset
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockERC4626Vault wethVault = new MockERC4626Vault(address(weth), "Yearn WETH", "yvWETH");

        // Allow the vault (but it has wrong asset)
        vm.prank(admin);
        erc4626Wrapper.addVault(address(wethVault));

        bytes memory depositData = abi.encodeWithSelector(
            erc4626Wrapper.DEPOSIT_SELECTOR(),
            address(wethVault), // Vault asset (WETH) != wallet base asset (USDC)
            500e6
        );

        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
    }
}
