// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {AgentWalletStorageV1} from "../src/lib/AgentWalletStorage.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title AgentWalletStorageV2
 * @notice Extended storage for V2 with new fields
 * @dev Creates a NEW namespace so V1 storage is untouched
 */
library AgentWalletStorageV2 {
    /// @custom:storage-location erc7201:yieldseeker.agentwallet.v2
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.v2");

    struct Layout {
        uint256 dummyValue;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}

/**
 * @title YieldSeekerAgentWalletV2
 * @notice Upgraded wallet with new dummyValue field
 * @dev Inherits from V1 and adds V2 storage namespace
 */
contract YieldSeekerAgentWalletV2 is YieldSeekerAgentWallet {
    event DummyValueSet(uint256 value);

    /**
     * @notice Initialize V2-specific storage
     * @dev Uses reinitializer(2) to ensure it only runs once
     */
    function initializeV2(uint256 _dummyValue) external reinitializer(2) {
        AgentWalletStorageV2.Layout storage $ = AgentWalletStorageV2.layout();
        $.dummyValue = _dummyValue;
        emit DummyValueSet(_dummyValue);
    }

    /**
     * @notice Get the dummy value
     */
    function dummyValue() public view returns (uint256) {
        return AgentWalletStorageV2.layout().dummyValue;
    }

    /**
     * @notice Set the dummy value
     */
    function setDummyValue(uint256 _dummyValue) external onlyOwner {
        AgentWalletStorageV2.Layout storage $ = AgentWalletStorageV2.layout();
        $.dummyValue = _dummyValue;
        emit DummyValueSet(_dummyValue);
    }

    /**
     * @notice Return the account ID (updated for V2)
     */
    function accountId() public view virtual override returns (string memory) {
        return "yieldseeker.agent.wallet.v2";
    }
}

contract WalletUpgradeTest is Test {
    YieldSeekerAgentWallet public implementationV1;
    YieldSeekerAgentWalletV2 public implementationV2;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    MockERC20 public usdc;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public operator = address(0x3);

    function setUp() public {
        vm.startPrank(admin);

        // Deploy V1 Implementation
        implementationV1 = new YieldSeekerAgentWallet();

        // Deploy V2 Implementation
        implementationV2 = new YieldSeekerAgentWalletV2();

        // Deploy Factory with V1
        factory = new YieldSeekerAgentWalletFactory(address(implementationV1), admin);

        // Deploy Policy & Router
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);

        // Set default executor
        factory.setDefaultExecutor(address(router));

        // Deploy Mock USDC
        usdc = new MockERC20("USDC", "USDC");

        vm.stopPrank();
    }

    function test_UpgradeWallet_PreservesV1Storage() public {
        // 1. Create V1 Wallet
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet walletV1 = YieldSeekerAgentWallet(payable(walletAddr));

        // 2. Deposit some funds
        usdc.mint(walletAddr, 1000e6);
        vm.deal(walletAddr, 1 ether);

        // 3. Verify V1 state
        assertEq(walletV1.user(), user);
        assertEq(walletV1.userAgentIndex(), 0);
        assertEq(walletV1.baseAsset(), address(usdc));
        assertEq(walletV1.accountId(), "yieldseeker.agent.wallet.v1");
        assertEq(usdc.balanceOf(walletAddr), 1000e6);
        assertEq(walletAddr.balance, 1 ether);

        // 4. User upgrades to V2 with initializeV2 call
        vm.prank(user);
        walletV1.upgradeToAndCall(address(implementationV2), abi.encodeCall(YieldSeekerAgentWalletV2.initializeV2, (42)));

        // 5. Cast to V2 interface
        YieldSeekerAgentWalletV2 walletV2 = YieldSeekerAgentWalletV2(payable(walletAddr));

        // 6. Verify V1 storage is PRESERVED
        assertEq(walletV2.user(), user, "Owner should be preserved");
        assertEq(walletV2.userAgentIndex(), 0, "userAgentIndex should be preserved");
        assertEq(walletV2.baseAsset(), address(usdc), "baseAsset should be preserved");
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "USDC balance should be preserved");
        assertEq(walletAddr.balance, 1 ether, "ETH balance should be preserved");
        assertTrue(walletV2.isModuleInstalled(2, address(router), ""), "Router should still be installed");

        // 7. Verify V2 storage is initialized
        assertEq(walletV2.dummyValue(), 42, "dummyValue should be set");
        assertEq(walletV2.accountId(), "yieldseeker.agent.wallet.v2", "accountId should be V2");

        // 8. Verify V2 functions work
        vm.prank(user);
        walletV2.setDummyValue(100);
        assertEq(walletV2.dummyValue(), 100, "dummyValue should be updated");

        // 9. Verify V1 functions still work
        vm.prank(user);
        walletV2.withdrawTokenToUser(address(usdc), user, 100e6);
        assertEq(usdc.balanceOf(walletAddr), 900e6, "Withdrawal should work");
        assertEq(usdc.balanceOf(user), 100e6, "User should receive USDC");
    }

    function test_UpgradeWallet_OnlyOwnerCanUpgrade() public {
        // Create wallet
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));

        // Operator cannot upgrade
        vm.prank(operator);
        vm.expectRevert();
        wallet.upgradeToAndCall(address(implementationV2), "");

        // Admin cannot upgrade
        vm.prank(admin);
        vm.expectRevert();
        wallet.upgradeToAndCall(address(implementationV2), "");

        // Random address cannot upgrade
        vm.prank(address(0x999));
        vm.expectRevert();
        wallet.upgradeToAndCall(address(implementationV2), "");

        // Only user (owner) can upgrade
        vm.prank(user);
        wallet.upgradeToAndCall(address(implementationV2), abi.encodeCall(YieldSeekerAgentWalletV2.initializeV2, (42)));

        // Verify upgrade succeeded
        YieldSeekerAgentWalletV2 walletV2 = YieldSeekerAgentWalletV2(payable(walletAddr));
        assertEq(walletV2.accountId(), "yieldseeker.agent.wallet.v2");
    }

    function test_UpgradeWallet_CannotReinitializeV2() public {
        // Create and upgrade wallet
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));

        vm.prank(user);
        wallet.upgradeToAndCall(address(implementationV2), abi.encodeCall(YieldSeekerAgentWalletV2.initializeV2, (42)));

        YieldSeekerAgentWalletV2 walletV2 = YieldSeekerAgentWalletV2(payable(walletAddr));

        // Try to call initializeV2 again - should fail
        vm.prank(user);
        vm.expectRevert();
        walletV2.initializeV2(100);

        // dummyValue should still be 42
        assertEq(walletV2.dummyValue(), 42);
    }

    function test_UpgradeWallet_AddressStaysSame() public {
        // Create wallet and record address
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Upgrade
        vm.prank(user);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToAndCall(address(implementationV2), abi.encodeCall(YieldSeekerAgentWalletV2.initializeV2, (42)));

        // Address should be identical
        YieldSeekerAgentWalletV2 walletV2 = YieldSeekerAgentWalletV2(payable(walletAddr));
        assertEq(address(walletV2), walletAddr, "Wallet address should not change after upgrade");
    }

    function test_NewWalletsGetV1_UntilFactoryUpdated() public {
        // Create wallet with V1 factory
        vm.prank(admin);
        address wallet1Addr = factory.createAgentWallet(user, 0, address(usdc));
        assertEq(YieldSeekerAgentWallet(payable(wallet1Addr)).accountId(), "yieldseeker.agent.wallet.v1");

        // Update factory to V2
        vm.prank(admin);
        factory.setImplementation(address(implementationV2));

        // Create new wallet - should be V2 but NOT initialized with V2 storage
        vm.prank(admin);
        address wallet2Addr = factory.createAgentWallet(address(0x999), 0, address(usdc));

        // The new wallet uses V2 implementation
        YieldSeekerAgentWalletV2 wallet2 = YieldSeekerAgentWalletV2(payable(wallet2Addr));
        assertEq(wallet2.accountId(), "yieldseeker.agent.wallet.v2");

        // But dummyValue is 0 since initializeV2 wasn't called
        assertEq(wallet2.dummyValue(), 0);

        // Old wallet still on V1
        assertEq(YieldSeekerAgentWallet(payable(wallet1Addr)).accountId(), "yieldseeker.agent.wallet.v1");
    }
}
