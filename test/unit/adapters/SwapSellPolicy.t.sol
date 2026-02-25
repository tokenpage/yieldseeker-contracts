// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {Test} from "forge-std/Test.sol";

contract SwapSellPolicyTest is Test {
    YieldSeekerSwapSellPolicy policy;

    address admin = address(0xA11CE);
    address emergencyAdmin = address(0xB0B);
    address nonAdmin = address(0xDEAD);
    address tokenA = address(0x1001);
    address tokenB = address(0x1002);

    function setUp() public {
        policy = new YieldSeekerSwapSellPolicy(admin, emergencyAdmin, false);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        new YieldSeekerSwapSellPolicy(address(0), emergencyAdmin, false);
    }

    function test_Constructor_RevertsOnZeroEmergencyAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        new YieldSeekerSwapSellPolicy(admin, address(0), false);
    }

    function test_AddSellableToken_AdminOnly() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        policy.addSellableToken(tokenA);
        vm.prank(admin);
        policy.addSellableToken(tokenA);
        assertTrue(policy.isSellableToken(tokenA));
    }

    function test_AddSellableToken_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        policy.addSellableToken(address(0));
    }

    function test_AddSellableTokens_BatchSucceeds() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        vm.prank(admin);
        policy.addSellableTokens(tokens);
        assertTrue(policy.isSellableToken(tokenA));
        assertTrue(policy.isSellableToken(tokenB));
        address[] memory listedTokens = policy.getSellableTokens();
        assertEq(listedTokens.length, 2);
    }

    function test_AddSellableTokens_RevertsOnZeroAddress() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = address(0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        policy.addSellableTokens(tokens);
        assertFalse(policy.isSellableToken(tokenA));
    }

    function test_RemoveSellableToken_EmergencyOnly() public {
        vm.prank(admin);
        policy.addSellableToken(tokenA);
        vm.prank(nonAdmin);
        vm.expectRevert();
        policy.removeSellableToken(tokenA);
        vm.prank(emergencyAdmin);
        policy.removeSellableToken(tokenA);
        assertFalse(policy.isSellableToken(tokenA));
    }

    function test_SetAllowSellingAllTokens_AdminOnly() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        policy.setAllowSellingAllTokens(true);
        vm.prank(admin);
        policy.setAllowSellingAllTokens(true);
        assertTrue(policy.allowSellingAllTokens());
        assertTrue(policy.isSellableToken(address(0x9999)));
    }

    function test_IsSellableToken_AllowlistAndAllowAllFlow() public {
        assertFalse(policy.isSellableToken(tokenA));
        vm.prank(admin);
        policy.addSellableToken(tokenA);
        assertTrue(policy.isSellableToken(tokenA));
        vm.prank(emergencyAdmin);
        policy.removeSellableToken(tokenA);
        assertFalse(policy.isSellableToken(tokenA));
        vm.prank(admin);
        policy.setAllowSellingAllTokens(true);
        assertTrue(policy.isSellableToken(tokenA));
        assertTrue(policy.isSellableToken(address(0xFFFF)));
    }
}
