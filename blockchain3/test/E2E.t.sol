// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {BatchRouter} from "../src/adapters/BatchRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAavePool.sol";

/**
 * @title E2E Tests
 * @notice End-to-end tests based on README example flows
 * @dev Tests the complete user journey from wallet creation to yield operations
 */
contract E2ETest is Test {
    // Core contracts
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    ActionRegistry public registry;

    // Adapters
    ERC4626Adapter public erc4626Adapter;
    AaveV3Adapter public aaveAdapter;
    BatchRouter public batchRouter;

    // Mock tokens and protocols
    MockERC20 public usdc;
    MockERC4626 public yearnVault;
    MockERC4626 public morphoVault;
    MockAavePool public aavePool;
    MockAToken public aUsdc;

    // Actors
    address public platformAdmin = address(0x1);
    address public user = address(0x2);
    address public operator = address(0x3);
    address public emergencyAdmin = address(0x4);
    address public attacker = address(0x5);
    address public user2 = address(0x6);

    // Events to test
    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);
    event Supplied(address indexed wallet, address indexed pool, address indexed asset, uint256 amount);

    function setUp() public {
        vm.startPrank(platformAdmin);
        usdc = new MockERC20("USD Coin", "USDC");
        yearnVault = new MockERC4626(address(usdc));
        morphoVault = new MockERC4626(address(usdc));
        aavePool = new MockAavePool();
        aUsdc = new MockAToken(address(usdc), "Aave USDC", "aUSDC");
        aUsdc.setPool(address(aavePool));
        aavePool.setAToken(address(usdc), address(aUsdc));
        usdc.mint(address(aavePool), 1_000_000e6);
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), platformAdmin);
        registry = new ActionRegistry(platformAdmin);
        router = new AgentActionRouter(address(registry), platformAdmin);
        router.addOperator(operator);
        router.grantRole(router.EMERGENCY_ROLE(), emergencyAdmin);
        registry.grantRole(registry.EMERGENCY_ROLE(), emergencyAdmin);
        factory.setDefaultExecutor(address(router));
        erc4626Adapter = new ERC4626Adapter(address(registry));
        aaveAdapter = new AaveV3Adapter(address(registry));
        batchRouter = new BatchRouter(address(registry));
        registry.registerAdapter(address(erc4626Adapter));
        registry.registerAdapter(address(aaveAdapter));
        registry.registerAdapter(address(batchRouter));
        registry.registerTarget(address(yearnVault), address(erc4626Adapter));
        registry.registerTarget(address(morphoVault), address(erc4626Adapter));
        registry.registerTarget(address(aavePool), address(aaveAdapter));
        vm.stopPrank();
    }

    // ============ Flow 1: Agent Wallet Creation ============

    /**
     * @notice Test complete wallet creation flow from README
     * @dev Verifies:
     *      - Deterministic address prediction
     *      - User is set as owner
     *      - Base asset is configured
     *      - Router module is auto-installed
     *      - Wallet is ready to receive deposits
     */
    function test_E2E_Flow1_WalletCreation() public {
        address predictedAddr = factory.predictAgentWalletAddress(user, 0, address(usdc));
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        assertEq(walletAddr, predictedAddr, "Address should be deterministic");
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(wallet.owner(), user, "User should be owner");
        assertEq(wallet.user(), user, "User should match");
        assertEq(wallet.userAgentIndex(), 0, "Index should be 0");
        assertEq(wallet.baseAsset(), address(usdc), "Base asset should be USDC");
        assertTrue(wallet.isModuleInstalled(2, address(router), ""), "Router should be installed");
        usdc.mint(walletAddr, 1000e6);
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "Wallet should receive deposits");
    }

    /**
     * @notice Test creating multiple wallets for same user
     */
    function test_E2E_Flow1_MultipleWalletsPerUser() public {
        vm.startPrank(platformAdmin);
        address wallet0 = factory.createAgentWallet(user, 0, address(usdc));
        address wallet1 = factory.createAgentWallet(user, 1, address(usdc));
        address wallet2 = factory.createAgentWallet(user, 2, address(usdc));
        vm.stopPrank();
        assertTrue(wallet0 != wallet1 && wallet1 != wallet2, "Each wallet should have unique address");
        assertEq(YieldSeekerAgentWallet(payable(wallet0)).userAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(wallet1)).userAgentIndex(), 1);
        assertEq(YieldSeekerAgentWallet(payable(wallet2)).userAgentIndex(), 2);
        assertEq(YieldSeekerAgentWallet(payable(wallet0)).owner(), user);
        assertEq(YieldSeekerAgentWallet(payable(wallet1)).owner(), user);
        assertEq(YieldSeekerAgentWallet(payable(wallet2)).owner(), user);
    }

    // ============ Flow 2: User Deposits USDC, Operator Manages Vault Positions ============

    /**
     * @notice Test complete yield management flow from README
     * @dev Step 1: User deposits USDC to wallet
     *      Step 2: Operator deposits into ERC4626 vault
     *      Step 3: Operator withdraws from vault
     *      Result: User has original USDC (+ any yield)
     */
    function test_E2E_Flow2_FullYieldManagementCycle() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "Step 1: Wallet should have 1000 USDC");
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        assertEq(usdc.balanceOf(walletAddr), 0, "Step 2: USDC should be in vault");
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6, "Step 2: Wallet should have shares");
        uint256 shares = yearnVault.balanceOf(walletAddr);
        bytes memory withdrawAction = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), shares));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), withdrawAction);
        assertEq(yearnVault.balanceOf(walletAddr), 0, "Step 3: Shares should be redeemed");
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "Step 3: USDC should be back");
        vm.prank(user);
        wallet.withdrawTokenToUser(address(usdc), user, 1000e6);
        assertEq(usdc.balanceOf(user), 1000e6, "User should receive their USDC");
    }

    /**
     * @notice Test operator moving funds between vaults for better yield
     */
    function test_E2E_Flow2_MoveBetweenVaults() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositYearn = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositYearn);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6, "Should be in Yearn");
        uint256 yearnShares = yearnVault.balanceOf(walletAddr);
        bytes memory withdrawYearn = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), yearnShares));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), withdrawYearn);
        bytes memory depositMorpho = abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositMorpho);
        assertEq(yearnVault.balanceOf(walletAddr), 0, "Should have exited Yearn");
        assertEq(morphoVault.balanceOf(walletAddr), 1000e6, "Should be in Morpho");
    }

    /**
     * @notice Test partial deposits and withdrawals
     */
    function test_E2E_Flow2_PartialOperations() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory deposit500 = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), deposit500);
        assertEq(usdc.balanceOf(walletAddr), 500e6, "500 USDC should remain");
        assertEq(yearnVault.balanceOf(walletAddr), 500e6, "500 shares in vault");
        bytes memory withdraw200 = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), 200e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), withdraw200);
        assertEq(usdc.balanceOf(walletAddr), 700e6, "Should have 700 USDC");
        assertEq(yearnVault.balanceOf(walletAddr), 300e6, "300 shares remaining");
    }

    // ============ Aave V3 Integration ============

    /**
     * @notice Test Aave supply and withdraw flow
     */
    function test_E2E_AaveV3_SupplyAndWithdraw() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory supplyAction = abi.encodeCall(AaveV3Adapter.supply, (address(aavePool), address(usdc), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(aaveAdapter), supplyAction);
        assertEq(usdc.balanceOf(walletAddr), 0, "USDC should be supplied");
        assertEq(aUsdc.balanceOf(walletAddr), 1000e6, "Should have aUSDC");
        bytes memory withdrawAction = abi.encodeCall(AaveV3Adapter.withdraw, (address(aavePool), address(usdc), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(aaveAdapter), withdrawAction);
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "USDC should be back");
        assertEq(aUsdc.balanceOf(walletAddr), 0, "aUSDC should be burned");
    }

    /**
     * @notice Test moving between ERC4626 and Aave
     */
    function test_E2E_CrossProtocol_ERC4626ToAave() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositErc4626 = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositErc4626);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6, "In ERC4626");
        uint256 shares = yearnVault.balanceOf(walletAddr);
        bytes memory withdrawErc4626 = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), shares));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), withdrawErc4626);
        bytes memory supplyAave = abi.encodeCall(AaveV3Adapter.supply, (address(aavePool), address(usdc), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(aaveAdapter), supplyAave);
        assertEq(yearnVault.balanceOf(walletAddr), 0, "Should have exited ERC4626");
        assertEq(aUsdc.balanceOf(walletAddr), 1000e6, "Should be in Aave");
    }

    // ============ Sequential Multi-Deposit Operations ============

    /**
     * @notice Test sequential deposits into multiple vaults
     * @dev Batch delegatecall is not supported by ERC-7579, so we use sequential calls
     */
    function test_E2E_SequentialDeposit_MultipleVaults() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.startPrank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 400e6))
        );
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 600e6))
        );
        vm.stopPrank();
        assertEq(usdc.balanceOf(walletAddr), 0, "All USDC should be deposited");
        assertEq(yearnVault.balanceOf(walletAddr), 400e6, "400 in Yearn");
        assertEq(morphoVault.balanceOf(walletAddr), 600e6, "600 in Morpho");
    }

    /**
     * @notice Test sequential deposits with mixed adapters (ERC4626 + Aave)
     */
    function test_E2E_SequentialDeposit_MixedAdapters() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.startPrank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6))
        );
        router.executeAdapterAction(
            walletAddr,
            address(aaveAdapter),
            abi.encodeCall(AaveV3Adapter.supply, (address(aavePool), address(usdc), 500e6))
        );
        vm.stopPrank();
        assertEq(yearnVault.balanceOf(walletAddr), 500e6, "500 in Yearn");
        assertEq(aUsdc.balanceOf(walletAddr), 500e6, "500 in Aave");
    }

    // ============ Security Scenarios ============

    /**
     * @notice Verify operator cannot withdraw to arbitrary address
     * @dev Key security property: operators can only deposit/withdraw within the wallet
     */
    function test_E2E_Security_OperatorCannotTransferDirectly() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(operator);
        vm.expectRevert();
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeWithSignature("transfer(address,uint256)", attacker, 1000e6)
        );
    }

    /**
     * @notice Verify operator cannot use unregistered vault
     */
    function test_E2E_Security_OperatorCannotUseUnregisteredVault() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        MockERC4626 maliciousVault = new MockERC4626(address(usdc));
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(maliciousVault), 1000e6));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(maliciousVault)));
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
    }

    /**
     * @notice Verify operator cannot use unregistered adapter
     */
    function test_E2E_Security_OperatorCannotUseUnregisteredAdapter() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        ERC4626Adapter fakeAdapter = new ERC4626Adapter(address(registry));
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentActionRouter.AdapterNotRegistered.selector, address(fakeAdapter)));
        router.executeAdapterAction(walletAddr, address(fakeAdapter), depositAction);
    }

    /**
     * @notice Verify random user cannot execute actions
     */
    function test_E2E_Security_RandomUserCannotOperate() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(attacker);
        vm.expectRevert("Router: not authorized");
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
    }

    /**
     * @notice Verify user retains withdrawal control at all times
     */
    function test_E2E_Security_UserAlwaysCanWithdraw() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        vm.prank(platformAdmin);
        router.removeOperator(operator);
        assertFalse(router.operators(operator), "Operator should be removed");
        vm.prank(user);
        wallet.withdrawTokenToUser(address(yearnVault), user, 1000e6);
        assertEq(yearnVault.balanceOf(user), 1000e6, "User can always withdraw shares");
    }

    /**
     * @notice Test emergency operator removal stops all operations
     */
    function test_E2E_Security_EmergencyOperatorRemoval() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        assertEq(yearnVault.balanceOf(walletAddr), 500e6, "First deposit works");
        vm.prank(emergencyAdmin);
        router.removeOperator(operator);
        vm.prank(operator);
        vm.expectRevert("Router: not authorized");
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6))
        );
        assertEq(usdc.balanceOf(walletAddr), 500e6, "Remaining USDC safe");
    }

    /**
     * @notice Test emergency target removal blocks vault operations
     */
    function test_E2E_Security_EmergencyTargetRemoval() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        vm.prank(emergencyAdmin);
        registry.removeTarget(address(yearnVault));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(yearnVault)));
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6))
        );
        bytes memory depositMorpho = abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositMorpho);
        assertEq(morphoVault.balanceOf(walletAddr), 500e6, "Morpho still works");
    }

    // ============ Multi-User Scenarios ============

    /**
     * @notice Test operator managing multiple user wallets
     */
    function test_E2E_MultiUser_OperatorManagesMultipleWallets() public {
        vm.startPrank(platformAdmin);
        address wallet1 = factory.createAgentWallet(user, 0, address(usdc));
        address wallet2 = factory.createAgentWallet(user2, 0, address(usdc));
        vm.stopPrank();
        usdc.mint(wallet1, 1000e6);
        usdc.mint(wallet2, 2000e6);
        vm.startPrank(operator);
        router.executeAdapterAction(
            wallet1,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6))
        );
        router.executeAdapterAction(
            wallet2,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 2000e6))
        );
        vm.stopPrank();
        assertEq(yearnVault.balanceOf(wallet1), 1000e6, "User1 in Yearn");
        assertEq(morphoVault.balanceOf(wallet2), 2000e6, "User2 in Morpho");
    }

    /**
     * @notice Verify one user cannot affect another's wallet
     */
    function test_E2E_MultiUser_WalletIsolation() public {
        vm.startPrank(platformAdmin);
        address wallet1 = factory.createAgentWallet(user, 0, address(usdc));
        address wallet2 = factory.createAgentWallet(user2, 0, address(usdc));
        vm.stopPrank();
        usdc.mint(wallet1, 1000e6);
        usdc.mint(wallet2, 1000e6);
        vm.prank(user);
        vm.expectRevert();
        YieldSeekerAgentWallet(payable(wallet2)).withdrawTokenToUser(address(usdc), user, 1000e6);
        assertEq(usdc.balanceOf(wallet2), 1000e6, "User2's funds are safe");
    }

    // ============ Event Verification ============

    /**
     * @notice Verify deposit emits correct event
     */
    function test_E2E_Events_DepositEmitsEvent() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.expectEmit(true, true, false, true);
        emit Deposited(walletAddr, address(yearnVault), 1000e6, 1000e6);
        vm.prank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6))
        );
    }

    /**
     * @notice Verify withdraw emits correct event
     */
    function test_E2E_Events_WithdrawEmitsEvent() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6))
        );
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(walletAddr, address(yearnVault), 1000e6, 1000e6);
        vm.prank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(erc4626Adapter),
            abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), 1000e6))
        );
    }

    /**
     * @notice Verify Aave supply emits correct event
     */
    function test_E2E_Events_AaveSupplyEmitsEvent() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        vm.expectEmit(true, true, true, true);
        emit Supplied(walletAddr, address(aavePool), address(usdc), 1000e6);
        vm.prank(operator);
        router.executeAdapterAction(
            walletAddr,
            address(aaveAdapter),
            abi.encodeCall(AaveV3Adapter.supply, (address(aavePool), address(usdc), 1000e6))
        );
    }

    // ============ Edge Cases ============

    /**
     * @notice Test zero balance operations
     */
    function test_E2E_EdgeCase_ZeroBalance() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 100e6));
        vm.prank(operator);
        vm.expectRevert();
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
    }

    /**
     * @notice Test depositing exact balance
     */
    function test_E2E_EdgeCase_ExactBalance() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 1000e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        assertEq(usdc.balanceOf(walletAddr), 0, "Should deposit all");
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6, "Should have all shares");
    }

    /**
     * @notice Test withdrawing more than available shares
     */
    function test_E2E_EdgeCase_WithdrawMoreThanBalance() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 500e6);
        bytes memory depositAction = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositAction);
        bytes memory withdrawAction = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), 1000e6));
        vm.prank(operator);
        vm.expectRevert();
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), withdrawAction);
    }

    /**
     * @notice Test wallet can receive ETH
     */
    function test_E2E_EdgeCase_ReceiveEth() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        vm.deal(address(this), 1 ether);
        (bool success,) = walletAddr.call{value: 1 ether}("");
        assertTrue(success, "Should receive ETH");
        assertEq(walletAddr.balance, 1 ether, "Should have ETH");
        vm.prank(user);
        YieldSeekerAgentWallet(payable(walletAddr)).withdrawEthToUser(user, 1 ether);
        assertEq(user.balance, 1 ether, "User should receive ETH");
    }

    // ============ Batch Operations ============

    /**
     * @notice Test depositing into multiple vaults in a single transaction
     * @dev This is the primary use case for BatchRouter - atomic multi-vault deposits
     *      Uses the ERC-7579 workaround: delegatecall to BatchRouter which internally
     *      delegatecalls to each adapter.
     */
    function test_E2E_BatchDeposit_MultipleVaults() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        address[] memory adapters = new address[](2);
        bytes[] memory actionDatas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(erc4626Adapter);
        actionDatas[0] = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 400e6));
        actionDatas[1] = abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 300e6));
        bytes memory batchData = abi.encodeCall(BatchRouter.executeBatch, (adapters, actionDatas));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(batchRouter), batchData);
        assertEq(yearnVault.balanceOf(walletAddr), 400e6, "Should have Yearn shares");
        assertEq(morphoVault.balanceOf(walletAddr), 300e6, "Should have Morpho shares");
        assertEq(usdc.balanceOf(walletAddr), 300e6, "Should have remaining USDC");
    }

    /**
     * @notice Test mixed deposit and withdraw in a single batch
     * @dev Demonstrates atomically rebalancing between vaults
     */
    function test_E2E_BatchRebalance_DepositAndWithdraw() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), depositData);
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
        address[] memory adapters = new address[](2);
        bytes[] memory actionDatas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(erc4626Adapter);
        actionDatas[0] = abi.encodeCall(ERC4626Adapter.withdraw, (address(yearnVault), 200e6));
        actionDatas[1] = abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 200e6));
        bytes memory batchData = abi.encodeCall(BatchRouter.executeBatch, (adapters, actionDatas));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(batchRouter), batchData);
        assertEq(yearnVault.balanceOf(walletAddr), 300e6, "Should have reduced Yearn shares");
        assertEq(morphoVault.balanceOf(walletAddr), 200e6, "Should have Morpho shares");
        assertEq(usdc.balanceOf(walletAddr), 500e6, "USDC unchanged after rebalance");
    }

    /**
     * @notice Test batch with mixed protocol adapters
     * @dev Deposits to both ERC4626 vault and Aave in single transaction
     */
    function test_E2E_BatchDeposit_CrossProtocol() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        address[] memory adapters = new address[](2);
        bytes[] memory actionDatas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(aaveAdapter);
        actionDatas[0] = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 400e6));
        actionDatas[1] = abi.encodeCall(AaveV3Adapter.supply, (address(aavePool), address(usdc), 300e6));
        bytes memory batchData = abi.encodeCall(BatchRouter.executeBatch, (adapters, actionDatas));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(batchRouter), batchData);
        assertEq(yearnVault.balanceOf(walletAddr), 400e6, "Should have Yearn shares");
        assertEq(aUsdc.balanceOf(walletAddr), 300e6, "Should have aTokens");
        assertEq(usdc.balanceOf(walletAddr), 300e6, "Should have remaining USDC");
    }

    /**
     * @notice Test that batch failures are atomic (all-or-nothing)
     * @dev If second action fails, first action should also be reverted
     */
    function test_E2E_BatchDeposit_AtomicFailure() public {
        vm.prank(platformAdmin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 500e6);
        address[] memory adapters = new address[](2);
        bytes[] memory actionDatas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(erc4626Adapter);
        actionDatas[0] = abi.encodeCall(ERC4626Adapter.deposit, (address(yearnVault), 400e6));
        actionDatas[1] = abi.encodeCall(ERC4626Adapter.deposit, (address(morphoVault), 400e6));
        bytes memory batchData = abi.encodeCall(BatchRouter.executeBatch, (adapters, actionDatas));
        vm.prank(operator);
        vm.expectRevert();
        router.executeAdapterAction(walletAddr, address(batchRouter), batchData);
        assertEq(yearnVault.balanceOf(walletAddr), 0, "First deposit should be reverted");
        assertEq(morphoVault.balanceOf(walletAddr), 0, "Second deposit should never happen");
        assertEq(usdc.balanceOf(walletAddr), 500e6, "USDC should be unchanged");
    }
}
