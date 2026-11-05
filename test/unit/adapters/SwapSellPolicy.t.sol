// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

contract SwapSellPolicyTest is Test {
    YieldSeekerSwapSellPolicy policy;

    address admin = address(0xA11CE);
    address emergencyAdmin = address(0xB0B);
    address nonAdmin = address(0xDEAD);
    address tokenA = address(0x1001);
    address tokenB = address(0x1002);
    address tokenC = address(0x1003);

    function setUp() public {
        policy = new YieldSeekerSwapSellPolicy(admin, emergencyAdmin, false);
    }

    function testConstructorRejectsZeroRoleAddresses() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        new YieldSeekerSwapSellPolicy(address(0), emergencyAdmin, false);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        new YieldSeekerSwapSellPolicy(admin, address(0), false);
    }

    function testAdminControlsAllowlistAndBatchAddRejectsZeroAddress() public {
        bytes memory notAdmin = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, bytes32(0));
        vm.expectRevert(notAdmin);
        vm.prank(nonAdmin);
        policy.addSellableToken(tokenA);
        assertFalse(policy.isSellableToken(tokenA));

        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        vm.prank(admin);
        policy.addSellableTokens(tokens);
        assertTrue(policy.isSellableToken(tokenA));
        assertTrue(policy.isSellableToken(tokenB));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        vm.prank(admin);
        policy.addSellableToken(address(0));

        address[] memory invalidTokens = new address[](2);
        invalidTokens[0] = tokenC;
        invalidTokens[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        vm.prank(admin);
        policy.addSellableTokens(invalidTokens);
        assertFalse(policy.isSellableToken(tokenC));
    }

    function testEmergencyRemovalAndAllowAllRequireTheirRespectiveRoles() public {
        vm.prank(admin);
        policy.addSellableToken(tokenA);

        bytes32 emergencyRole = policy.EMERGENCY_ROLE();
        bytes memory notEmergencyAdmin = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, emergencyRole);
        vm.expectRevert(notEmergencyAdmin);
        vm.prank(nonAdmin);
        policy.removeSellableToken(tokenA);
        assertTrue(policy.isSellableToken(tokenA));

        vm.prank(emergencyAdmin);
        policy.removeSellableToken(tokenA);
        assertFalse(policy.isSellableToken(tokenA));

        bytes memory notAdmin = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, bytes32(0));
        vm.expectRevert(notAdmin);
        vm.prank(nonAdmin);
        policy.setAllowSellingAllTokens(true);
        assertFalse(policy.isSellableToken(tokenB));

        vm.prank(admin);
        policy.setAllowSellingAllTokens(true);
        assertTrue(policy.isSellableToken(tokenA));
        assertTrue(policy.isSellableToken(tokenB));
    }
}
