// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerMerklAdapter} from "../../../src/adapters/MerklAdapter.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterFeeSetup, AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract MockMerklDistributor {
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function claim(address[] calldata, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata) external {
        if (shouldRevert) revert("claim failed");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(MockERC20(tokens[i]).transfer(msg.sender, amounts[i]), "Transfer failed");
        }
    }
}

contract MerklAdapterTest is Test {
    YieldSeekerMerklAdapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockMerklDistributor distributor;
    MockERC20 baseAsset;
    MockERC20 rewardToken;

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        rewardToken = new MockERC20("Reward", "RWD");
        (feeTracker,) = AdapterFeeSetup.deploy(address(0xBEEF), 5000, 1000);
        adapter = new YieldSeekerMerklAdapter();
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        distributor = new MockMerklDistributor();
        baseAsset.mint(address(distributor), 1_000_000e6);
        rewardToken.mint(address(distributor), 1_000_000e18);
    }

    function test_Claim_BaseAssetRecordsFee() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        address[] memory tokens = new address[](1);
        tokens[0] = address(baseAsset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        uint256 feeCollectorBalanceBefore = baseAsset.balanceOf(feeTracker.feeCollector());
        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));

        assertEq(baseAsset.balanceOf(address(wallet)), 900e6);
        assertEq(wallet.vaultFeeModule().feesOwed(address(wallet)), 0);
        assertEq(baseAsset.balanceOf(feeTracker.feeCollector()) - feeCollectorBalanceBefore, 100e6);
        assertEq(wallet.vaultFeeModule().feesCharged(address(wallet)), 100e6);
        assertEq(wallet.vaultFeeModule().feesPaid(address(wallet)), 100e6);
    }

    function test_Claim_DuplicateNonBaseTokensRecordsNoFee() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken);
        tokens[1] = address(rewardToken);
        tokens[2] = address(rewardToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 50e18;
        amounts[2] = 25e18;
        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        proofs[2] = new bytes32[](0);

        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));

        assertEq(rewardToken.balanceOf(address(wallet)), amounts[0] + amounts[1] + amounts[2]);
        assertEq(wallet.vaultFeeModule().feesCharged(address(wallet)), 0);
        assertEq(wallet.vaultFeeModule().feesPaid(address(wallet)), 0);
    }

    function test_Claim_MixedTokens_TracksOnlyBaseAssetFee() public {
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        address[] memory tokens = new address[](2);
        tokens[0] = address(baseAsset);
        tokens[1] = address(rewardToken);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e6;
        amounts[1] = 10e18;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);

        uint256 feeCollectorBalanceBefore = baseAsset.balanceOf(feeTracker.feeCollector());
        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));

        assertEq(baseAsset.balanceOf(address(wallet)), 450e6);
        assertEq(wallet.vaultFeeModule().feesOwed(address(wallet)), 0);
        assertEq(baseAsset.balanceOf(feeTracker.feeCollector()) - feeCollectorBalanceBefore, 50e6);
        assertEq(wallet.vaultFeeModule().feesCharged(address(wallet)), 50e6);
        assertEq(wallet.vaultFeeModule().feesPaid(address(wallet)), 50e6);
        assertEq(rewardToken.balanceOf(address(wallet)), amounts[1]);
    }

    function test_Claim_RevertPropagates() public {
        distributor.setShouldRevert(true);
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        address[] memory tokens = new address[](1);
        tokens[0] = address(baseAsset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        vm.expectRevert();
        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));
    }
}
