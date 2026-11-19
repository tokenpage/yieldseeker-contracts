// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerMerklAdapter} from "../../src/adapters/MerklAdapter.sol";
import {IMerklDistributor} from "../../src/agentwalletkit/adapters/AWKMerklAdapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMerklRoot {
    function getMerkleRoot() external view returns (bytes32);
}

/// @dev Claims through the live Base Merkl distributor. Its current and previous roots (storage slots 101 and 103 on
///      Base, November 2026) are replaced with a one-leaf tree for the wallet, so the empty proof is valid.
contract MerklForkTest is ForkBase {
    address internal constant MERKL = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant TREE_ROOT_SLOT = 101;
    uint256 internal constant LAST_TREE_ROOT_SLOT = 103;

    YieldSeekerMerklAdapter internal merklAdapter;

    function setUp() public override {
        super.setUp();
        merklAdapter = new YieldSeekerMerklAdapter();
        _registerAdapter(address(merklAdapter), MERKL);
    }

    function test_LiveDistributorClaimsAreChargedOnExactlyWhatItPaid() public {
        AgentWallet wallet = _createVaultWallet(USDC, 0);
        deal(USDC, MERKL, IERC20(USDC).balanceOf(MERKL) + 1_500e6);
        _claim(wallet, 1_000e6);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 900e6);
        assertEq(IERC20(USDC).balanceOf(feeCollector), 100e6);

        _claim(wallet, 1_500e6);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 1_350e6);
        assertEq(IERC20(USDC).balanceOf(feeCollector), 150e6);
        (uint208 recorded,,) = IMerklDistributor(MERKL).claimed(address(wallet), USDC);
        assertEq(recorded, 1_500e6);
    }

    function test_LiveDistributorRefusesAStrangerClaimingForTheWallet() public {
        AgentWallet wallet = _createVaultWallet(USDC, 0);
        bytes32 root = keccak256(abi.encode(address(wallet), USDC, uint256(1_000e6)));
        vm.store(MERKL, bytes32(TREE_ROOT_SLOT), root);
        vm.store(MERKL, bytes32(LAST_TREE_ROOT_SLOT), root);
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.prank(makeAddr("stranger"), makeAddr("stranger"));
        vm.expectRevert();
        IMerklDistributor(MERKL).claim(users, tokens, amounts, proofs);
    }

    function _claim(AgentWallet wallet, uint256 cumulativeAmount) internal {
        bytes32 root = keccak256(abi.encode(address(wallet), USDC, cumulativeAmount));
        vm.store(MERKL, bytes32(TREE_ROOT_SLOT), root);
        vm.store(MERKL, bytes32(LAST_TREE_ROOT_SLOT), root);
        assertEq(IMerklRoot(MERKL).getMerkleRoot(), root);
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = cumulativeAmount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        _execute(wallet, address(merklAdapter), MERKL, abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
    }
}
