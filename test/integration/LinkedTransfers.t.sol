pragma solidity 0.8.28;

import {InvalidAsset, YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {SameWallet} from "../../src/WalletLinkRegistry.sol";
import {InvalidTransferTarget, NotLinkedWallet} from "../../src/adapters/AgentTransferAdapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract LinkedTransferSpoofWallet {
    address private immutable _owner;
    uint256 private immutable _index;

    constructor(address walletOwner, uint256 index) {
        _owner = walletOwner;
        _index = index;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function ownerAgentIndex() external view returns (uint256) {
        return _index;
    }
}

contract LinkedTransfersTest is IntegrationBase {
    address private immutable invalidTarget = address(0xD00D);

    function testOwnerLinksWalletsAndTransfersBaseAssetInBothDirections() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        uint256 initialVaultBalance = 300e6;
        uint256 initialBorrowBalance = 200e6;
        _fundWallet(vaultWallet, address(usdc), initialVaultBalance);
        _fundWallet(borrowWallet, address(usdc), initialBorrowBalance);
        _link(vaultWallet, borrowWallet);

        uint256 toBorrow = 80e6;
        _transfer(vaultWallet, address(usdc), address(borrowWallet), toBorrow);
        assertEq(usdc.balanceOf(address(vaultWallet)), initialVaultBalance - toBorrow);
        assertEq(usdc.balanceOf(address(borrowWallet)), initialBorrowBalance + toBorrow);

        uint256 toVault = 25e6;
        _transfer(borrowWallet, address(usdc), address(vaultWallet), toVault);
        assertEq(usdc.balanceOf(address(vaultWallet)), initialVaultBalance - toBorrow + toVault);
        assertEq(usdc.balanceOf(address(borrowWallet)), initialBorrowBalance + toBorrow - toVault);
    }

    function testLinkedWalletsTransferBorrowedTokenOnlyWhenBothTrackIt() public {
        AgentWallet first = _createBorrowWallet(owner, 1);
        AgentWallet second = _createBorrowWallet(owner, 2);
        uint256 collateral = 100e6;
        uint256 borrowed = 1e18;
        _borrowWeth(first, collateral, borrowed);
        _borrowWeth(second, collateral, borrowed);
        _link(first, second);

        uint256 toSecond = 25e16;
        _transfer(first, address(weth), address(second), toSecond);
        assertEq(weth.balanceOf(address(first)), borrowed - toSecond);
        assertEq(weth.balanceOf(address(second)), borrowed + toSecond);

        uint256 toFirst = 10e16;
        _transfer(second, address(weth), address(first), toFirst);
        assertEq(weth.balanceOf(address(first)), borrowed - toSecond + toFirst);
        assertEq(weth.balanceOf(address(second)), borrowed + toSecond - toFirst);
    }

    function testBorrowProfileFeeSettlesFromBaseAssetBeforeCrossProfileTransfer() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        _link(vaultWallet, borrowWallet);
        _borrowWeth(borrowWallet, 100e6, 1e18);

        uint256 elapsed = 365 days;
        uint256 debtAmount = 1e18;
        uint256 expectedFee = (debtAmount * BORROW_FEE_BPS * elapsed) / (365 days * 10_000);
        expectedFee = (expectedFee * 2_000 * (10 ** uint256(usdc.decimals()))) / (10 ** uint256(weth.decimals()));
        vm.warp(vm.getBlockTimestamp() + elapsed);
        bytes memory repayData = abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max));
        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), repayData);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), expectedFee);

        uint256 transferAmount = 30e6;
        _fundWallet(borrowWallet, address(usdc), expectedFee + transferAmount);
        uint256 collectorBalanceBefore = _feesCollected(address(usdc));
        _transfer(borrowWallet, address(usdc), address(vaultWallet), transferAmount);

        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(usdc.balanceOf(address(vaultWallet)), transferAmount);
        assertEq(_feesCollected(address(usdc)) - collectorBalanceBefore, expectedFee);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
        assertEq(borrowYieldFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function testTransferRollsBackFeeSettlementWhenAmountExceedsPostFeeBalance() public {
        AgentWallet borrowWallet = _createBorrowWallet(owner, 1);
        AgentWallet vaultWallet = _createVaultWallet(owner, 2);
        _link(vaultWallet, borrowWallet);
        _borrowWeth(borrowWallet, 100e6, 1e18);

        uint256 elapsed = 365 days;
        uint256 debtAmount = 1e18;
        uint256 expectedFee = (debtAmount * BORROW_FEE_BPS * elapsed) / (365 days * 10_000);
        expectedFee = (expectedFee * 2_000 * (10 ** uint256(usdc.decimals()))) / (10 ** uint256(weth.decimals()));
        vm.warp(vm.getBlockTimestamp() + elapsed);
        bytes memory repayData = abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max));
        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), repayData);
        _fundWallet(borrowWallet, address(usdc), expectedFee);

        uint256 collectorBalanceBefore = _feesCollected(address(usdc));
        bytes memory innerError = abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector);
        _executeExpectRevert(borrowWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(vaultWallet), 1)), innerError);

        assertEq(usdc.balanceOf(address(borrowWallet)), expectedFee);
        assertEq(usdc.balanceOf(address(vaultWallet)), 0);
        assertEq(_feesCollected(address(usdc)), collectorBalanceBefore);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), expectedFee);
    }

    function testLinkRegistryRequiresSameOwnerAndRejectsSameWallet() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        AgentWallet otherOwnerWallet = _createVaultWallet(makeAddr("otherOwner"), 1);
        address otherOwner = otherOwnerWallet.owner();

        vm.prank(owner);
        vm.expectRevert(SameWallet.selector);
        walletLinkRegistry.setLinked(address(vaultWallet), address(vaultWallet), true);

        bytes memory unauthorizedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, otherOwner);
        vm.expectRevert(unauthorizedError);
        vm.prank(otherOwner);
        walletLinkRegistry.setLinked(address(vaultWallet), address(borrowWallet), true);

        vm.expectRevert(unauthorizedError);
        vm.prank(otherOwner);
        walletLinkRegistry.setLinked(address(vaultWallet), address(borrowWallet), false);

        vm.prank(owner);
        walletLinkRegistry.setLinked(address(vaultWallet), address(borrowWallet), true);
        assertTrue(walletLinkRegistry.isLinked(address(vaultWallet), address(borrowWallet)));
        assertTrue(walletLinkRegistry.isLinked(address(borrowWallet), address(vaultWallet)));
        vm.prank(owner);
        walletLinkRegistry.setLinked(address(vaultWallet), address(borrowWallet), false);
        assertFalse(walletLinkRegistry.isLinked(address(vaultWallet), address(borrowWallet)));
    }

    function testTransferRequiresRegisteredLinkedWalletAndRegistryTarget() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        AgentWallet otherOwnerWallet = _createVaultWallet(makeAddr("otherOwner"), 1);
        _fundWallet(vaultWallet, address(usdc), 100e6);

        vaultRegistry.setTargetAdapter(invalidTarget, address(agentTransferAdapter));
        borrowRegistry.setTargetAdapter(invalidTarget, address(agentTransferAdapter));

        bytes memory notLinkedError = abi.encodeWithSelector(NotLinkedWallet.selector, address(borrowWallet));
        _executeExpectRevert(vaultWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(borrowWallet), 1)), notLinkedError);
        _link(vaultWallet, borrowWallet);

        LinkedTransferSpoofWallet spoof = new LinkedTransferSpoofWallet(owner, borrowWallet.ownerAgentIndex());
        bytes memory spoofError = abi.encodeWithSelector(NotLinkedWallet.selector, address(spoof));
        _executeExpectRevert(vaultWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(spoof), 1)), spoofError);

        bytes memory otherOwnerError = abi.encodeWithSelector(NotLinkedWallet.selector, address(otherOwnerWallet));
        _executeExpectRevert(vaultWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(otherOwnerWallet), 1)), otherOwnerError);

        bytes memory targetError = abi.encodeWithSelector(InvalidTransferTarget.selector, invalidTarget);
        _executeExpectRevert(vaultWallet, address(agentTransferAdapter), invalidTarget, abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(borrowWallet), 1)), targetError);
    }

    function testTransferRejectsTokensNotAccountedByReceiverAndZeroAmounts() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        _borrowWeth(borrowWallet, 100e6, 1e18);
        _link(vaultWallet, borrowWallet);

        assertTrue(borrowFeeModule.isAccountedToken(address(borrowWallet), address(weth)));
        assertFalse(vaultFeeTracker.isAccountedToken(address(vaultWallet), address(weth)));
        bytes memory invalidAssetError = abi.encodeWithSelector(InvalidAsset.selector);
        _executeExpectRevert(borrowWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(weth), address(vaultWallet), 1)), invalidAssetError);

        bytes memory zeroAmountError = abi.encodeWithSelector(AWKErrors.ZeroAmount.selector);
        _executeExpectRevert(vaultWallet, address(agentTransferAdapter), address(walletLinkRegistry), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(borrowWallet), 0)), zeroAmountError);
    }

    function _borrowWeth(AgentWallet wallet, uint256 collateral, uint256 borrowed) private {
        _fundWallet(wallet, address(usdc), collateral);
        bytes memory supplyData = abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateral));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), supplyData);
        bytes memory borrowData = abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowed));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), borrowData);
    }

    function _link(AgentWallet first, AgentWallet second) private {
        vm.prank(owner);
        walletLinkRegistry.setLinked(address(first), address(second), true);
    }

    function _transfer(AgentWallet from, address token, address to, uint256 amount) private {
        bytes memory data = abi.encodeCall(agentTransferAdapter.transfer, (token, to, amount));
        _execute(from, address(agentTransferAdapter), address(walletLinkRegistry), data);
    }
}
