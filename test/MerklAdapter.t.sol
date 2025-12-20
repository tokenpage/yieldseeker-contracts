// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerFeeLedger as FeeLedger} from "../src/FeeLedger.sol";
import {YieldSeekerMerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, console2} from "forge-std/Test.sol";

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
    FeeLedger ledger;
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

        ledger = new FeeLedger(admin);
        vm.prank(admin);
        ledger.setFeeConfig(1000, feeCollector); // 10% fee

        registry = new AdapterRegistry(admin, admin);

        factory = new AgentWalletFactory(admin, admin);
        vm.startPrank(admin);
        factory.setAdapterRegistry(registry);
        factory.setFeeLedger(ledger);
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

        // Check reward tracking
        assertEq(ledger.getAgentRewardTokenBalance(address(wallet), address(aero)), 100e18);

        // No fees yet (only on swap to base asset)
        assertEq(ledger.agentFeesCharged(address(wallet)), 0);
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

        // Check reward tracking - AERO tracked, USDC counted as yield immediately
        assertEq(ledger.getAgentRewardTokenBalance(address(wallet), address(aero)), 100e18);
        assertEq(ledger.getAgentRewardTokenBalance(address(wallet), address(usdc)), 0); // Not tracked, it's base asset

        // USDC is base asset, so fee charged immediately
        assertEq(ledger.agentFeesCharged(address(wallet)), 5e6); // 10% of 50e6
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
        assertEq(ledger.getAgentRewardTokenBalance(address(wallet), address(usdc)), 0);

        // Fee charged immediately
        assertEq(ledger.agentFeesCharged(address(wallet)), 10e6); // 10% of 100e6
    }
}
