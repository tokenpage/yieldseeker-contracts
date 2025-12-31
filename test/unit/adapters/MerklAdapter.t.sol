// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {YieldSeekerMerklAdapter} from "../../../src/adapters/MerklAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
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
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF));
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

        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));

        assertEq(baseAsset.balanceOf(address(wallet)), 1_000e6);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 100e6);
    }

    function test_Claim_DuplicateTokens_DeduplicatesFeeTracking() public {
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

        uint256 totalClaimed = amounts[0] + amounts[1] + amounts[2];
        uint256 expectedFeeToken = (totalClaimed * 1000) / 10_000;
        uint256 owed = feeTracker.agentYieldTokenFeesOwed(address(wallet), address(rewardToken));
        assertEq(owed, expectedFeeToken);
    }

    function test_Claim_MixedTokens_TracksSeparately() public {
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

        wallet.executeAdapter(address(adapter), address(distributor), abi.encodeWithSelector(adapter.claim.selector, users, tokens, amounts, proofs));

        assertEq(baseAsset.balanceOf(address(wallet)), 500e6);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 50e6);
        uint256 owed = feeTracker.agentYieldTokenFeesOwed(address(wallet), address(rewardToken));
        assertEq(owed, (amounts[1] * 1000) / 10_000);
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
