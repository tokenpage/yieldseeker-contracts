// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {NotAllowed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockV3EchoAdapter, MockV3SelfManagedWallet, MockV3SelfManagedWalletV2, MockV3WalletFactory} from "../mocks/MockV3TestHelpers.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

contract AWKAgentWalletV3SelfManagedTest is Test {
    address private owner = makeAddr("owner");
    address private operator = makeAddr("operator");
    address private stranger = makeAddr("stranger");

    YieldSeekerAdapterRegistry private registry;
    MockV3EchoAdapter private adapter;
    MockV3SelfManagedWallet private wallet;

    function setUp() public {
        registry = new YieldSeekerAdapterRegistry(address(this), address(this));
        adapter = new MockV3EchoAdapter();
        wallet = _deploySelfManaged(owner);
    }

    function test_OwnerConfiguresRegistryAndOperatorsAndOperatorExecutesRegisteredAdapter() public {
        address target = address(0xBEEF);
        registry.registerAdapter(address(adapter));
        registry.setTargetAdapter(target, address(adapter));

        address[] memory operators = new address[](1);
        operators[0] = operator;
        vm.startPrank(owner);
        wallet.setAdapterRegistry(registry);
        wallet.setAgentOperators(operators);
        vm.stopPrank();

        bytes memory opData = hex"12345678";
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(address(adapter), target, opData);
        bytes memory innerResult = abi.decode(result, (bytes));
        (address returnedTarget, bytes memory returnedData) = abi.decode(innerResult, (address, bytes));

        assertEq(returnedTarget, target);
        assertEq(returnedData, opData);
        assertTrue(wallet.isAgentOperator(operator));
        assertEq(address(wallet.adapterRegistry()), address(registry));
    }

    function test_NonOwnerCannotConfigureRegistryOrOperators() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        wallet.setAdapterRegistry(registry);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        wallet.setAgentOperators(operators);
    }

    function test_SelfManagedSyncIsNoopAndUpgradeToLatestIsForbidden() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        vm.startPrank(owner);
        wallet.setAdapterRegistry(registry);
        wallet.setAgentOperators(operators);
        wallet.syncFromFactory();
        vm.expectRevert(NotAllowed.selector);
        wallet.upgradeToLatest();
        vm.stopPrank();

        assertEq(address(wallet.adapterRegistry()), address(registry));
        assertTrue(wallet.isAgentOperator(operator));
    }

    function test_OwnerCanUpgradeSelfManagedWalletToAValidArbitraryImplementation() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        vm.startPrank(owner);
        wallet.setAdapterRegistry(registry);
        wallet.setAgentOperators(operators);
        MockV3SelfManagedWalletV2 nextImplementation = new MockV3SelfManagedWalletV2(address(0));
        wallet.upgradeToAndCall(address(nextImplementation), "");
        vm.stopPrank();

        assertEq(MockV3SelfManagedWalletV2(payable(address(wallet))).version(), 2);
        assertEq(wallet.owner(), owner);
        assertEq(address(wallet.adapterRegistry()), address(registry));
        assertTrue(wallet.isAgentOperator(operator));
    }

    function test_SetAgentOperatorsReplacesThePreviousSet() public {
        address replacement = makeAddr("replacement");
        address[] memory first = new address[](1);
        first[0] = operator;
        address[] memory second = new address[](1);
        second[0] = replacement;
        vm.startPrank(owner);
        wallet.setAgentOperators(first);
        wallet.setAgentOperators(second);
        vm.stopPrank();

        assertFalse(wallet.isAgentOperator(operator));
        assertTrue(wallet.isAgentOperator(replacement));
        assertEq(wallet.listAgentOperators().length, 1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator));
        wallet.executeViaAdapter(address(adapter), address(0xBEEF), hex"12345678");
    }

    function test_FactoryManagedWalletCannotSetSelfManagedConfiguration() public {
        MockV3WalletFactory mockFactory = new MockV3WalletFactory();
        address[] memory operators = new address[](1);
        operators[0] = operator;
        mockFactory.setConfiguration(address(registry), address(0x1234), operators);
        MockV3SelfManagedWallet implementation = new MockV3SelfManagedWallet(address(mockFactory));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address,uint256,bytes32)", owner, 0, bytes32(0)));
        MockV3SelfManagedWallet managedWallet = MockV3SelfManagedWallet(payable(address(proxy)));

        vm.prank(owner);
        vm.expectRevert(NotAllowed.selector);
        managedWallet.setAdapterRegistry(registry);

        vm.prank(owner);
        vm.expectRevert(NotAllowed.selector);
        managedWallet.setAgentOperators(operators);
    }

    function _deploySelfManaged(address walletOwner) private returns (MockV3SelfManagedWallet deployed) {
        MockV3SelfManagedWallet implementation = new MockV3SelfManagedWallet(address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address,uint256,bytes32)", walletOwner, 0, bytes32(0)));
        deployed = MockV3SelfManagedWallet(payable(address(proxy)));
    }
}
