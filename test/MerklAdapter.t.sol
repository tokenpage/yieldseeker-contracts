// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {YieldSeekerMerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockMerklDistributor {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            MockToken(tokens[i]).mint(users[0], amounts[i]);
        }
    }
}

contract MerklAdapterTest is Test {
    AgentWallet wallet;
    FeeTracker tracker;
    AdapterRegistry registry;
    AgentWalletFactory factory;
    YieldSeekerMerklAdapter adapter;
    MockMerklDistributor distributor;
    MockToken usdc;
    MockToken aero;

    address admin = address(0x1);
    address owner = address(0x2);
    address feeCollector = address(0x3);

    function setUp() public {
        // Deploy core contracts
        usdc = new MockToken("USDC", "USDC");
        aero = new MockToken("AERO", "AERO");

        tracker = new FeeTracker(admin);
        vm.prank(admin);
        tracker.setFeeConfig(1000, feeCollector); // 10% fee

        registry = new AdapterRegistry(admin, admin);

        factory = new AgentWalletFactory(admin, admin);
        vm.startPrank(admin);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(tracker);
        vm.stopPrank();

        // Deploy adapter and distributor
        adapter = new YieldSeekerMerklAdapter();
        distributor = new MockMerklDistributor();

        // Register adapter
        vm.prank(admin);
        registry.registerAdapter(address(adapter));
        vm.prank(admin);
        registry.setTargetAdapter(address(distributor), address(adapter));

        // Deploy wallet implementation and set in factory
        AgentWallet walletImpl = new AgentWallet(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(walletImpl);

        // Create wallet
        vm.prank(admin);
        wallet = factory.createAgentWallet(owner, 1, address(usdc));
    }

    function test_ClaimSingleRewardToken() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);

        address[] memory tokens = new address[](1);
        tokens[0] = address(aero);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        bytes memory data = abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs);

        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(distributor), data);

        // Check token balance
        assertEq(aero.balanceOf(address(wallet)), 100e18);

        // Check yield tracking - stores 10% as fee owed in AERO
        assertEq(tracker.getAgentYieldTokenFeesOwed(address(wallet), address(aero)), 10e18);

        // No fees charged yet (only when swapped to base asset)
        assertEq(tracker.agentFeesCharged(address(wallet)), 0);
    }

    function test_ClaimMultipleRewardTokens() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);

        address[] memory tokens = new address[](2);
        tokens[0] = address(aero);
        tokens[1] = address(usdc);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e6;

        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        bytes memory data = abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs);

        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(distributor), data);

        // Check token balances
        assertEq(aero.balanceOf(address(wallet)), 100e18);
        assertEq(usdc.balanceOf(address(wallet)), 50e6);

        // Check yield tracking - AERO stored as 10% fee owed, USDC counted as yield immediately
        assertEq(tracker.getAgentYieldTokenFeesOwed(address(wallet), address(aero)), 10e18);
        assertEq(tracker.getAgentYieldTokenFeesOwed(address(wallet), address(usdc)), 0); // Not tracked, it's base asset

        // USDC is base asset, so fee charged immediately
        assertEq(tracker.agentFeesCharged(address(wallet)), 5e6); // 10% of 50e6
    }

    function test_ClaimBaseAssetReward() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        bytes memory data = abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs);

        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(distributor), data);

        // Check token balance
        assertEq(usdc.balanceOf(address(wallet)), 100e6);

        // USDC is base asset - should be recorded as yield immediately, not tracked
        assertEq(tracker.getAgentYieldTokenFeesOwed(address(wallet), address(usdc)), 0);

        // Fee charged immediately
        assertEq(tracker.agentFeesCharged(address(wallet)), 10e6); // 10% of 100e6
    }

    /**
     * @notice Regression test for duplicate token attack
     * @dev Verifies that duplicate tokens in the claim array don't inflate fee charges
     */
    function test_ClaimWithDuplicateTokens_DoesNotDoubleCoun() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);

        // Attack: Same token appears twice in the array
        address[] memory tokens = new address[](3);
        tokens[0] = address(aero);
        tokens[1] = address(usdc);
        tokens[2] = address(aero); // DUPLICATE!

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18; // 100 AERO
        amounts[1] = 50e6; // 50 USDC
        amounts[2] = 0; // Duplicate entry (Merkl won't distribute again)

        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        proofs[2] = new bytes32[](0);

        bytes memory data = abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs);

        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(distributor), data);

        // Check token balances - only 100 AERO distributed (Merkl doesn't double-distribute)
        assertEq(aero.balanceOf(address(wallet)), 100e18, "Should have 100 AERO");
        assertEq(usdc.balanceOf(address(wallet)), 50e6, "Should have 50 USDC");

        // Critical check: Fee should be 10% of 100 AERO, NOT 10% of 200 AERO
        assertEq(tracker.getAgentYieldTokenFeesOwed(address(wallet), address(aero)), 10e18, "Should only record 10 AERO fee, not 20");

        // USDC fee should be normal
        assertEq(tracker.agentFeesCharged(address(wallet)), 5e6, "Should charge 10% of 50 USDC");
    }
}
