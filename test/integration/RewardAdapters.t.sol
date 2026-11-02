// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {InvalidClaimHolder} from "../../src/agentwalletkit/adapters/AWKMoonwellRewardAdapter.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockMoonwellDualRewardComptroller {
    IERC20 public immutable wellToken;
    IERC20 public immutable baseAsset;
    uint256 public wellPerMarket;
    uint256 public basePerMarket;

    constructor(IERC20 wellToken_, IERC20 baseAsset_, uint256 wellPerMarket_, uint256 basePerMarket_) {
        wellToken = wellToken_;
        baseAsset = baseAsset_;
        wellPerMarket = wellPerMarket_;
        basePerMarket = basePerMarket_;
    }

    function claimReward(address holder, address[] calldata markets) external {
        for (uint256 i; i < markets.length; ++i) {
            require(wellToken.transfer(holder, wellPerMarket), "WELL transfer failed");
            require(baseAsset.transfer(holder, basePerMarket), "Base transfer failed");
        }
    }
}

contract RewardAdaptersTest is IntegrationBase {
    function _merklCall(AgentWallet wallet, address[] memory tokens, uint256[] memory amounts) private view returns (bytes memory) {
        address[] memory users = new address[](1);
        users[0] = address(wallet);
        bytes32[][] memory proofs = new bytes32[][](tokens.length);
        for (uint256 i; i < proofs.length; ++i) {
            proofs[i] = new bytes32[](0);
        }
        return abi.encodeCall(merklAdapter.claim, (users, tokens, amounts, proofs));
    }

    function testMerklClaimsBaseRewardsImmediatelyAndDeduplicatesRewardTokenAccounting() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(rewardToken);
        tokens[2] = address(rewardToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 500e6;
        amounts[1] = 100e18;
        amounts[2] = 25e18;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(wallet, tokens, amounts));

        uint256 baseFee = amounts[0] * YIELD_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(address(wallet)), amounts[0] - baseFee);
        assertEq(rewardToken.balanceOf(address(wallet)), amounts[1] + amounts[2]);
        assertEq(_feesCollected(address(usdc)), baseFee);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), amounts[0] - baseFee);
    }

    function testMerklClaimsOfOnlyNonBaseTokensDoNotChargeYieldFees() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken);
        tokens[1] = address(rewardToken);
        tokens[2] = address(rewardToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 50e18;
        amounts[2] = 25e18;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(wallet, tokens, amounts));

        assertEq(rewardToken.balanceOf(address(wallet)), amounts[0] + amounts[1] + amounts[2]);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(_feesCollected(address(usdc)), 0);
    }

    function testMerklClaimFailureRevertsTheWalletAction() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        merklDistributor.setShouldRevert(true);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        bytes memory expectedError = abi.encodeWithSignature("Error(string)", "claim failed");
        _executeExpectRevert(wallet, address(merklAdapter), address(merklDistributor), _merklCall(wallet, tokens, amounts), expectedError);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(_feesCollected(address(usdc)), 0);
    }

    function testMoonwellClaimCollectsBaseAssetFeeAndKeepsWELLRewardsInWallet() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 wellReward = 200e18;
        uint256 baseReward = 500e6;
        MockMoonwellDualRewardComptroller comptroller = new MockMoonwellDualRewardComptroller(IERC20(address(wellToken)), IERC20(address(usdc)), wellReward, baseReward);
        _fund(address(wellToken), address(comptroller), wellReward);
        _fund(address(usdc), address(comptroller), baseReward);
        vaultRegistry.setTargetAdapter(address(comptroller), address(moonwellRewardAdapter));
        address[] memory markets = new address[](1);
        markets[0] = address(0x1111);

        _execute(wallet, address(moonwellRewardAdapter), address(comptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (address(wallet), markets)));

        uint256 baseFee = baseReward * YIELD_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(address(wallet)), baseReward - baseFee);
        assertEq(wellToken.balanceOf(address(wallet)), wellReward);
        assertEq(_feesCollected(address(usdc)), baseFee);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), baseReward - baseFee);
    }

    function testMoonwellClaimRejectsAHolderOtherThanTheWallet() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory markets = new address[](1);
        markets[0] = address(0x1111);
        bytes memory holderError = abi.encodeWithSelector(InvalidClaimHolder.selector, owner);
        _executeExpectRevert(wallet, address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (owner, markets)), holderError);
    }

    function testMoonwellComptrollerFailureRevertsTheWalletAction() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        moonwellComptroller.setShouldRevert(true);
        address[] memory markets = new address[](1);
        markets[0] = address(0x1111);
        bytes memory expectedError = abi.encodeWithSignature("Error(string)", "claim failed");
        _executeExpectRevert(wallet, address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeCall(moonwellRewardAdapter.claimReward, (address(wallet), markets)), expectedError);
        assertEq(wellToken.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }
}
