// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {InvalidAsset, YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {SameWallet, YieldSeekerWalletLinkRegistry} from "../../src/WalletLinkRegistry.sol";
import {YieldSeekerAgentTransferAdapter} from "../../src/adapters/AgentTransferAdapter.sol";
import {InvalidTransferTarget, NotLinkedWallet} from "../../src/adapters/AgentTransferAdapter.sol";
import {AdapterExecutionFailed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3BorrowReporter, MockV3FakeWallet, MockV3YieldSeekerWalletV1} from "../mocks/MockV3TestHelpers.sol";
import {Test} from "forge-std/Test.sol";

contract WalletLinkTransferTest is Test {
    bytes32 private constant VAULT_AGENT_PROFILE = keccak256("vault-profile");
    bytes32 private constant BORROW_AGENT_PROFILE = keccak256("borrow-profile");

    address private constant OPERATOR = address(0xA11CE);
    address private owner = makeAddr("owner");
    address private otherOwner = makeAddr("other-owner");
    address private feeCollector = makeAddr("fee-collector");

    MockERC20 private usdc;
    MockERC20 private weth;
    MockERC20 private unrelated;
    YieldSeekerAdapterRegistry private vaultRegistry;
    YieldSeekerAdapterRegistry private borrowRegistry;
    YieldSeekerFeeTracker private vaultFees;
    YieldSeekerVaultFeeModule private vaultFeeModule;
    YieldSeekerBorrowFeeModule private borrowFees;
    YieldSeekerAgentWalletFactory private factory;
    YieldSeekerWalletLinkRegistry private linkRegistry;
    YieldSeekerAgentTransferAdapter private transferAdapter;
    MockV3BorrowReporter private borrowReporter;
    YieldSeekerAgentWalletV3 private vaultWallet;
    YieldSeekerAgentWalletV3 private borrowWallet;
    YieldSeekerAgentWalletV3 private otherOwnerWallet;
    address private immutableTarget = address(0xD00D);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");
        unrelated = new MockERC20("Unrelated", "NOPE");
        vaultRegistry = new YieldSeekerAdapterRegistry(address(this), address(this));
        borrowRegistry = new YieldSeekerAdapterRegistry(address(this), address(this));
        vaultFees = new YieldSeekerFeeTracker(address(this), address(this), feeCollector);
        vaultFeeModule = new YieldSeekerVaultFeeModule(vaultFees, 10_000);
        vaultFees.setFeeModule(VAULT_FEE, vaultFeeModule);
        vaultFees.setPlanRate(0, VAULT_FEE, 1_000);
        borrowFees = new YieldSeekerBorrowFeeModule(vaultFees, 1_000);
        vaultFees.setFeeModule(BORROW_FEE, borrowFees);
        vaultFees.setPlanRate(0, BORROW_FEE, 1_000);
        factory = new YieldSeekerAgentWalletFactory(address(this), OPERATOR);
        linkRegistry = new YieldSeekerWalletLinkRegistry();
        transferAdapter = new YieldSeekerAgentTransferAdapter(linkRegistry);
        borrowReporter = new MockV3BorrowReporter(borrowFees);

        MockV3YieldSeekerWalletV1 implementation = new MockV3YieldSeekerWalletV1(address(factory));
        factory.setAgentWalletImplementation(implementation);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, vaultRegistry);
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, borrowRegistry);
        factory.setFeeTracker(vaultFees);

        vaultRegistry.registerAdapter(address(transferAdapter));
        vaultRegistry.setTargetAdapter(address(linkRegistry), address(transferAdapter));
        vaultRegistry.setTargetAdapter(immutableTarget, address(transferAdapter));
        borrowRegistry.registerAdapter(address(transferAdapter));
        borrowRegistry.setTargetAdapter(address(linkRegistry), address(transferAdapter));
        borrowRegistry.setTargetAdapter(immutableTarget, address(transferAdapter));
        borrowRegistry.registerAdapter(address(borrowReporter));
        borrowRegistry.setTargetAdapter(address(borrowFees), address(borrowReporter));

        vm.startPrank(OPERATOR);
        vaultWallet = factory.createAgentWallet(owner, 1, address(usdc), VAULT_AGENT_PROFILE);
        borrowWallet = factory.createAgentWallet(owner, 2, address(weth), BORROW_AGENT_PROFILE);
        otherOwnerWallet = factory.createAgentWallet(otherOwner, 1, address(usdc), VAULT_AGENT_PROFILE);
        vm.stopPrank();

        usdc.mint(address(vaultWallet), 300e6);
        weth.mint(address(borrowWallet), 200e6);
        unrelated.mint(address(vaultWallet), 20e6);
    }

    function test_LinkRegistryRequiresSharedOwnerAndStoresSymmetricLinks() public {
        _linkWallets();
        assertTrue(linkRegistry.isLinked(address(vaultWallet), address(borrowWallet)));
        assertTrue(linkRegistry.isLinked(address(borrowWallet), address(vaultWallet)));

        vm.prank(owner);
        vm.expectRevert(SameWallet.selector);
        linkRegistry.setLinked(address(vaultWallet), address(vaultWallet), true);

        vm.prank(otherOwner);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, otherOwner));
        linkRegistry.setLinked(address(vaultWallet), address(otherOwnerWallet), true);

        vm.prank(otherOwner);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, otherOwner));
        linkRegistry.setLinked(address(vaultWallet), address(borrowWallet), false);
    }

    function test_LinkedWalletsTransferBaseAndBorrowedAssetsInBothDirections() public {
        _linkWallets();
        _recordBorrowedUsdc();
        _transfer(vaultWallet, address(usdc), address(borrowWallet), 80e6, address(linkRegistry));
        assertEq(usdc.balanceOf(address(vaultWallet)), 220e6);
        assertEq(usdc.balanceOf(address(borrowWallet)), 80e6);

        _transfer(borrowWallet, address(usdc), address(vaultWallet), 25e6, address(linkRegistry));
        assertEq(usdc.balanceOf(address(vaultWallet)), 245e6);
        assertEq(usdc.balanceOf(address(borrowWallet)), 55e6);
    }

    function test_TransferRejectsTokenTheReceiverCannotWithdraw() public {
        _linkWallets();
        _expectTransferFailure(vaultWallet, address(linkRegistry), address(usdc), address(borrowWallet), 1, abi.encodeWithSelector(InvalidAsset.selector));
    }

    function test_TransferRequiresLinkedWallet() public {
        _expectTransferFailure(vaultWallet, address(linkRegistry), address(usdc), address(borrowWallet), 1, abi.encodeWithSelector(NotLinkedWallet.selector, address(borrowWallet)));
    }

    function test_TransferRejectsSpoofWalletEvenWhenItClaimsTheSameOwnerAndIndex() public {
        _linkWallets();
        MockV3FakeWallet fakeWallet = new MockV3FakeWallet(owner, borrowWallet.ownerAgentIndex());
        _expectTransferFailure(vaultWallet, address(linkRegistry), address(usdc), address(fakeWallet), 1, abi.encodeWithSelector(NotLinkedWallet.selector, address(fakeWallet)));
    }

    function test_TransferRejectsWalletOwnedBySomeoneElse() public {
        _linkWallets();
        _expectTransferFailure(vaultWallet, address(linkRegistry), address(usdc), address(otherOwnerWallet), 1, abi.encodeWithSelector(NotLinkedWallet.selector, address(otherOwnerWallet)));
    }

    function test_TransferTargetMustBeTheLinkRegistry() public {
        _linkWallets();
        _expectTransferFailure(vaultWallet, immutableTarget, address(usdc), address(borrowWallet), 1, abi.encodeWithSelector(InvalidTransferTarget.selector, immutableTarget));
    }

    function test_TransferTokenMustBeAllowedByBothWallets() public {
        _linkWallets();
        _expectTransferFailure(vaultWallet, address(linkRegistry), address(unrelated), address(borrowWallet), 1, abi.encodeWithSelector(InvalidAsset.selector));
    }

    function test_TransferCannotExceedFeeModuleWithdrawableBalance() public {
        _linkWallets();
        _recordBorrowedUsdc();
        vm.prank(address(vaultWallet));
        vaultFeeModule.recordYield(100e6);

        _expectTransferFailure(vaultWallet, address(linkRegistry), address(usdc), address(borrowWallet), 290e6 + 1, abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector));
    }

    function _linkWallets() private {
        vm.prank(owner);
        linkRegistry.setLinked(address(vaultWallet), address(borrowWallet), true);
    }

    function _recordBorrowedUsdc() private {
        bytes32 market = keccak256("borrowed-usdc-market");
        bytes memory report = abi.encode(market, address(usdc), 100e6, 0);
        vm.prank(owner);
        borrowWallet.executeViaAdapter(address(borrowReporter), address(borrowFees), report);
    }

    function _transfer(YieldSeekerAgentWalletV3 from, address token, address to, uint256 amount, address target) private {
        bytes memory callData = abi.encodeWithSelector(transferAdapter.transfer.selector, token, to, amount);
        vm.prank(owner);
        from.executeViaAdapter(address(transferAdapter), target, callData);
    }

    function _expectTransferFailure(YieldSeekerAgentWalletV3 from, address target, address token, address to, uint256 amount, bytes memory innerReason) private {
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, innerReason));
        _transfer(from, token, to, amount, target);
    }
}
