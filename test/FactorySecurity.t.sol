// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerErrors} from "../src/Errors.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
}

contract FactorySecurityTest is Test {
    YieldSeekerAgentWalletFactory factory;
    AgentWallet impl;
    AdapterRegistry registry;
    FeeTracker tracker;
    MockUSDC usdc;

    address admin = address(0xAD);
    address operator = address(0x01);
    address owner = address(0x02);
    address eoa = address(0x1234);

    function setUp() public {
        factory = new YieldSeekerAgentWalletFactory(admin, operator);
        impl = new AgentWallet(address(factory));
        registry = new AdapterRegistry(admin, admin);
        usdc = new MockUSDC();

        tracker = new FeeTracker(admin);

        vm.startPrank(admin);
        factory.setAgentWalletImplementation(impl);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(tracker);
        vm.stopPrank();
    }

    function test_RevertSetAdapterRegistry_EOA() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.NotAContract.selector, eoa));
        factory.setAdapterRegistry(AdapterRegistry(eoa));
    }

    function test_RevertSetFeeTracker_EOA() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.NotAContract.selector, eoa));
        factory.setFeeTracker(FeeTracker(eoa));
    }

    function test_RevertCreateAgentWallet_EOAAsset() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.NotAContract.selector, eoa));
        factory.createAgentWallet(owner, 1, eoa);
    }

    function test_RevertInitialize_EOAAsset() public {
        // Deploy a proxy to test initialize
        bytes memory initData = ""; // Don't initialize yet
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AgentWallet walletProxy = AgentWallet(payable(address(proxy)));

        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.NotAContract.selector, eoa));
        walletProxy.initialize(owner, 1, eoa);
    }

    function test_RevertSync_IfRegistryBecomesEOA() public {
        // Create a wallet first
        vm.prank(operator);
        AgentWallet wallet = factory.createAgentWallet(owner, 1, address(usdc));

        // Deploy a new registry
        AdapterRegistry registry2 = new AdapterRegistry(admin, admin);

        // Set it in factory
        vm.prank(admin);
        factory.setAdapterRegistry(registry2);

        // Now "destroy" it by etching empty code over it
        // (In reality this would be selfdestruct or just a bad address if we could set it)
        vm.etch(address(registry2), "");

        // Sync wallet should revert
        vm.prank(owner);
        vm.expectRevert(AgentWallet.InvalidRegistry.selector);
        wallet.syncFromFactory();
    }
}
