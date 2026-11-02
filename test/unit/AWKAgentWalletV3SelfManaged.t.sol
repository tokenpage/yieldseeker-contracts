// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {NotAllowed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockV3EchoAdapter, MockV3SelfManagedWallet, MockV3SelfManagedWalletV2} from "../mocks/MockV3TestHelpers.sol";
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

    function testOwnerConfiguresRegistryOperatorsAndReplacesOperators() public {
        address target = address(0xBEEF);
        address replacement = makeAddr("replacement");
        registry.registerAdapter(address(adapter));
        registry.setTargetAdapter(target, address(adapter));

        address[] memory operators = new address[](1);
        operators[0] = operator;
        vm.prank(owner);
        wallet.setAdapterRegistry(registry);
        vm.prank(owner);
        wallet.setAgentOperators(operators);

        bytes memory opData = hex"12345678";
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(address(adapter), target, opData);
        (address returnedTarget, bytes memory returnedData) = abi.decode(abi.decode(result, (bytes)), (address, bytes));
        assertEq(returnedTarget, target);
        assertEq(returnedData, opData);

        operators[0] = replacement;
        vm.prank(owner);
        wallet.setAgentOperators(operators);
        assertFalse(wallet.isAgentOperator(operator));
        assertTrue(wallet.isAgentOperator(replacement));

        bytes memory unauthorizedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator);
        vm.expectRevert(unauthorizedError);
        vm.prank(operator);
        wallet.executeViaAdapter(address(adapter), target, opData);

        vm.prank(replacement);
        result = wallet.executeViaAdapter(address(adapter), target, opData);
        (returnedTarget, returnedData) = abi.decode(abi.decode(result, (bytes)), (address, bytes));
        assertEq(returnedTarget, target);
        assertEq(returnedData, opData);
        assertEq(address(wallet.adapterRegistry()), address(registry));
    }

    function testNonOwnerCannotConfigureRegistryOrOperators() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        bytes memory unauthorizedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger);

        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        wallet.setAdapterRegistry(registry);

        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        wallet.setAgentOperators(operators);
    }

    function testSyncIsNoopLatestUpgradeIsForbiddenAndOwnerMayUpgradeArbitrarily() public {
        address[] memory operators = new address[](1);
        operators[0] = operator;
        MockV3SelfManagedWalletV2 nextImplementation = new MockV3SelfManagedWalletV2();

        vm.startPrank(owner);
        wallet.setAdapterRegistry(registry);
        wallet.setAgentOperators(operators);
        wallet.syncFromFactory();
        vm.expectRevert(NotAllowed.selector);
        wallet.upgradeToLatest();
        wallet.upgradeToAndCall(address(nextImplementation), "");
        vm.stopPrank();

        MockV3SelfManagedWalletV2 upgradedWallet = MockV3SelfManagedWalletV2(payable(address(wallet)));
        assertEq(upgradedWallet.version(), 2);
        assertEq(wallet.owner(), owner);
        assertEq(address(wallet.adapterRegistry()), address(registry));
        assertTrue(wallet.isAgentOperator(operator));
    }

    function _deploySelfManaged(address walletOwner) private returns (MockV3SelfManagedWallet deployed) {
        MockV3SelfManagedWallet implementation = new MockV3SelfManagedWallet();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address,uint256,bytes32)", walletOwner, 0, bytes32(0)));
        deployed = MockV3SelfManagedWallet(payable(address(proxy)));
    }
}
