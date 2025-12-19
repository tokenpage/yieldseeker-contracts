// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerFeeLedger as FeeLedger} from "../src/FeeLedger.sol";
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
    FeeLedger ledger;
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

        FeeLedger ledgerImpl = new FeeLedger();
        ERC1967Proxy ledgerProxy = new ERC1967Proxy(address(ledgerImpl), abi.encodeWithSelector(FeeLedger.initialize.selector, admin));
        ledger = FeeLedger(address(ledgerProxy));

        vm.startPrank(admin);
        factory.setAgentWalletImplementation(impl);
        factory.setAdapterRegistry(registry);
        factory.setFeeLedger(ledger);
        vm.stopPrank();
    }

    function test_RevertSetAdapterRegistry_EOA() public {
        vm.prank(admin);
        vm.expectRevert(YieldSeekerAgentWalletFactory.InvalidAddress.selector);
        factory.setAdapterRegistry(AdapterRegistry(eoa));
    }

    function test_RevertSetFeeLedger_EOA() public {
        vm.prank(admin);
        vm.expectRevert(YieldSeekerAgentWalletFactory.InvalidAddress.selector);
        factory.setFeeLedger(FeeLedger(eoa));
    }

    function test_RevertCreateAccount_EOAAsset() public {
        vm.prank(operator);
        vm.expectRevert(YieldSeekerAgentWalletFactory.InvalidAddress.selector);
        factory.createAccount(owner, 1, eoa);
    }

    function test_RevertInitialize_EOAAsset() public {
        // Deploy a proxy to test initialize
        bytes memory initData = ""; // Don't initialize yet
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AgentWallet walletProxy = AgentWallet(payable(address(proxy)));

        vm.expectRevert("Invalid base asset");
        walletProxy.initialize(owner, 1, eoa);
    }

    function test_RevertSync_IfRegistryBecomesEOA() public {
        // Create a wallet first
        vm.prank(operator);
        AgentWallet wallet = factory.createAccount(owner, 1, address(usdc));

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
