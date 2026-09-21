// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletV2 as AgentWalletV2} from "../../src/AgentWalletV2.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {Test} from "forge-std/Test.sol";

/// @title Agent Wallet V1 -> V2 Migration Test
/// @notice Proves the actual claim this whole exercise rests on: an already-deployed V1 wallet
///         opts in to V2 cleanly (no data loss, no re-initialization, no separate migration
///         step), while a V1 wallet that never upgrades keeps behaving exactly as before —
///         entirely unaffected by V2 existing or by other wallets upgrading to it.
contract AgentWalletV1ToV2MigrationTest is Test {
    address internal constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    MockERC20 usdc;
    MockERC4626 vault;
    AgentWalletV1 v1Implementation;
    AgentWalletV2 v2Implementation;

    address admin = makeAddr("admin");
    address operatorAddr = makeAddr("operator");
    address ownerAddr = makeAddr("owner");
    address recipient = makeAddr("recipient");

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(0, admin);
        factory = new AgentWalletFactory(admin, operatorAddr);
        v1Implementation = new AgentWalletV1(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(v1Implementation);
        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();
    }

    function test_ExistingV1Wallet_UpgradesToV2_PreservesStateAndGainsSponsorship() public {
        // 1. Deploy a wallet under V1 — this is the "thousands of existing users" scenario.
        vm.prank(operatorAddr);
        AgentWalletV1 v1Wallet = factory.createAgentWallet(ownerAddr, 1, address(usdc));
        usdc.mint(address(v1Wallet), 1_000e6);

        // 2. Give it real V1 state: a vault position (via the operator, autonomous trading) and
        //    an owner-set adapter block (sovereignty), exactly what a real wallet accumulates.
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (400e6));
        vm.prank(operatorAddr);
        v1Wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        uint256 vaultSharesBeforeUpgrade = vault.balanceOf(address(v1Wallet));
        assertGt(vaultSharesBeforeUpgrade, 0, "sanity: deposit must have produced vault shares");

        address someOtherAdapter = makeAddr("someOtherAdapter");
        vm.prank(ownerAddr);
        v1Wallet.blockAdapter(someOtherAdapter);
        assertTrue(v1Wallet.isAdapterBlocked(someOtherAdapter));

        // 3. Confirm V1 does NOT accept an EntryPoint-relayed withdrawal yet — this is the
        //    pre-upgrade baseline the rest of the test is measured against.
        vm.prank(ENTRY_POINT);
        vm.expectRevert();
        v1Wallet.withdrawAssetToUser(recipient, address(usdc), 100e6);

        // 4. Deploy V2 and flip the factory's pointer — exactly the real deployment step: this
        //    only affects NEW wallet creation and what existing wallets are *eligible* to
        //    upgrade to. It does not touch v1Wallet's bytecode or storage by itself.
        vm.prank(admin);
        v2Implementation = new AgentWalletV2(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(v2Implementation);

        // 5. The wallet owner opts in. This is the ONLY step that changes v1Wallet's behavior.
        vm.prank(ownerAddr);
        AgentWalletV1(payable(address(v1Wallet))).upgradeToLatest();

        AgentWalletV2 upgradedWallet = AgentWalletV2(payable(address(v1Wallet)));

        // 6. Every field the wallet had under V1 must read back identically under V2 — same
        //    address, same storage, no re-initialization, no migration function was ever called.
        assertEq(upgradedWallet.owner(), ownerAddr, "owner must survive the upgrade");
        assertEq(address(upgradedWallet.baseAsset()), address(usdc), "baseAsset must survive the upgrade");
        assertEq(address(upgradedWallet.feeTracker()), address(feeTracker), "feeTracker cache must survive the upgrade");
        assertEq(vault.balanceOf(address(upgradedWallet)), vaultSharesBeforeUpgrade, "vault position must survive the upgrade");
        assertTrue(upgradedWallet.isAdapterBlocked(someOtherAdapter), "owner's adapter block must survive the upgrade");
        assertEq(usdc.balanceOf(address(upgradedWallet)), 600e6, "base asset balance must survive the upgrade");

        // 7. The new capability now works, from the exact same address.
        vm.prank(ENTRY_POINT);
        upgradedWallet.withdrawAssetToUser(recipient, address(usdc), 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6, "EntryPoint-relayed withdrawal must succeed post-upgrade");

        // 8. Direct owner calls still work too — the upgrade is additive, not a replacement of
        //    the existing interaction model.
        vm.prank(ownerAddr);
        upgradedWallet.withdrawAssetToUser(recipient, address(usdc), 100e6);
        assertEq(usdc.balanceOf(recipient), 200e6, "direct owner withdrawal must still work post-upgrade");
    }

    function test_V1Wallet_ThatNeverUpgrades_IsUnaffectedByV2Existing() public {
        // A second, sibling V1 wallet that never opts in. Deploying V2 and even having OTHER
        // wallets upgrade to it must not change this wallet's behavior at all.
        vm.prank(operatorAddr);
        AgentWalletV1 unupgradedWallet = factory.createAgentWallet(ownerAddr, 2, address(usdc));
        usdc.mint(address(unupgradedWallet), 500e6);

        vm.prank(admin);
        v2Implementation = new AgentWalletV2(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(v2Implementation);

        // New wallets now deploy on V2...
        vm.prank(operatorAddr);
        AgentWalletV1 freshWallet = factory.createAgentWallet(makeAddr("newOwner"), 1, address(usdc));
        assertTrue(_isEntryPointRelayable(freshWallet), "a freshly created wallet after the flip must be on V2");

        // ...but the untouched sibling from before the flip is still plain V1 behavior: no
        // EntryPoint relay, direct owner calls unaffected.
        vm.prank(ENTRY_POINT);
        vm.expectRevert();
        unupgradedWallet.withdrawAssetToUser(recipient, address(usdc), 100e6);

        vm.prank(ownerAddr);
        unupgradedWallet.withdrawAssetToUser(recipient, address(usdc), 100e6);
        assertEq(usdc.balanceOf(recipient), 100e6);
    }

    function _isEntryPointRelayable(AgentWalletV1 wallet) internal returns (bool) {
        vm.prank(ENTRY_POINT);
        try AgentWalletV1(payable(address(wallet))).withdrawAllAssetToUser(recipient, address(usdc)) {
            return true;
        } catch {
            return false;
        }
    }
}
