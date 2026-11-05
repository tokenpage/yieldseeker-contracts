// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AssetNotAllowed} from "../../src/adapters/Adapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {MockAToken, MockAaveV3Pool} from "../mocks/MockAaveV3.sol";
import {MockCNativeToken, MockCToken} from "../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../mocks/MockCompoundV3.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract VaultAdaptersTest is IntegrationBase {
    function _decodeUint(bytes memory result) private pure returns (uint256) {
        return abi.decode(abi.decode(result, (bytes)), (uint256));
    }

    function _createWalletForAsset(address walletOwner, uint256 index, address asset) private returns (AgentWallet wallet) {
        FeePlanChoice[] memory feePlans = new FeePlanChoice[](0);
        vm.prank(operator);
        wallet = AgentWallet(payable(address(factory.createAgentWallet(walletOwner, index, asset, VAULT_AGENT_PROFILE, feePlans))));
    }

    function testERC4626ShareValueAndProfitableWithdrawalsSettleFeesImmediately() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 firstDeposit = 1_000e6;
        uint256 secondDeposit = 500e6;
        uint256 donatedAssets = 1_000e6;
        _fundWallet(wallet, address(usdc), firstDeposit + secondDeposit);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (firstDeposit)));
        _fund(address(usdc), address(erc4626Vault), donatedAssets);
        bytes memory secondDepositResult = _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (secondDeposit)));
        (uint256 secondShares, uint256 assetsDeposited) = abi.decode(abi.decode(secondDepositResult, (bytes)), (uint256, uint256));
        assertEq(secondShares, 250e6);
        assertEq(assetsDeposited, secondDeposit);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 1_250e6);

        bytes memory firstWithdrawalResult = _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (1_000e6)));
        assertEq(_decodeUint(firstWithdrawalResult), 2_000e6);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 300e6);
        assertEq(_feesCollected(address(usdc)), 80e6);

        bytes memory finalWithdrawalResult = _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (250e6)));
        assertEq(_decodeUint(finalWithdrawalResult), 500e6);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(_feesCollected(address(usdc)), 100e6);
        assertEq(usdc.balanceOf(address(wallet)), 2_400e6);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), 2_400e6);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testDepositPercentageUsesTheWalletBalanceForEachVaultAdapter() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 4_000e6);

        address[4] memory adapters = [address(erc4626Adapter), address(aaveV3Adapter), address(compoundV2Adapter), address(compoundV3Adapter)];
        address[4] memory targets = [address(erc4626Vault), address(aaveV3Vault), address(compoundV2Vault), address(compoundV3Market)];
        for (uint256 i; i < adapters.length; ++i) {
            uint256 balanceBefore = usdc.balanceOf(address(wallet));
            uint256 expectedDeposit = balanceBefore / 4;
            bytes memory result = _execute(wallet, adapters[i], targets[i], abi.encodeWithSelector(bytes4(keccak256("depositPercentage(uint256)")), 2_500));
            (, uint256 assetsDeposited) = abi.decode(abi.decode(result, (bytes)), (uint256, uint256));
            assertEq(assetsDeposited, expectedDeposit);
            assertEq(usdc.balanceOf(address(wallet)), balanceBefore - expectedDeposit);
        }
    }

    function testVaultAdaptersRejectZeroAmountsAndWrongUnderlyingAssets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        bytes memory zeroAmount = abi.encodeWithSelector(AWKErrors.ZeroAmount.selector);

        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.deposit, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.withdraw, (0)), zeroAmount);
        _executeExpectRevert(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (0)), zeroAmount);

        MockERC4626 wrongERC4626 = new MockERC4626(address(rewardToken), "Wrong ERC4626", "w4626");
        MockAaveV3Pool wrongAavePool = new MockAaveV3Pool(address(rewardToken));
        MockAToken wrongAToken = MockAToken(wrongAavePool.aToken());
        MockCToken wrongCToken = new MockCToken(address(rewardToken), "Wrong cToken", "wcToken");
        MockCompoundV3Comet wrongComet = new MockCompoundV3Comet(address(rewardToken));
        vaultRegistry.setTargetAdapter(address(wrongERC4626), address(erc4626Adapter));
        vaultRegistry.setTargetAdapter(address(wrongAToken), address(aaveV3Adapter));
        vaultRegistry.setTargetAdapter(address(wrongCToken), address(compoundV2Adapter));
        vaultRegistry.setTargetAdapter(address(wrongComet), address(compoundV3Adapter));
        bytes memory invalidAsset = abi.encodeWithSelector(AssetNotAllowed.selector);

        _executeExpectRevert(wallet, address(erc4626Adapter), address(wrongERC4626), abi.encodeCall(erc4626Adapter.deposit, (1e6)), invalidAsset);
        _executeExpectRevert(wallet, address(aaveV3Adapter), address(wrongAToken), abi.encodeCall(aaveV3Adapter.deposit, (1e6)), invalidAsset);
        _executeExpectRevert(wallet, address(compoundV2Adapter), address(wrongCToken), abi.encodeCall(compoundV2Adapter.deposit, (1e6)), invalidAsset);
        _executeExpectRevert(wallet, address(compoundV3Adapter), address(wrongComet), abi.encodeCall(compoundV3Adapter.deposit, (1e6)), invalidAsset);

        uint256 foreignShares = 1e18;
        _fund(address(rewardToken), address(this), foreignShares);
        rewardToken.approve(address(wrongERC4626), foreignShares);
        wrongERC4626.deposit(foreignShares, address(wallet));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(wrongERC4626), abi.encodeCall(erc4626Adapter.withdraw, (foreignShares)), invalidAsset);
        assertEq(wrongERC4626.balanceOf(address(wallet)), foreignShares);
    }

    function testERC4626WithdrawalChargesYieldOnAssetsActuallyReceived() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principal = 1_000e6;
        uint256 yieldAmount = 100e6;
        _fundWallet(wallet, address(usdc), principal);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (principal)));
        _fund(address(usdc), address(erc4626Vault), yieldAmount);
        erc4626Vault.setRedeemFee(100);
        uint256 received = (principal + yieldAmount) * 9_900 / 10_000;
        uint256 expectedFee = Math.mulDiv(received - principal, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 shares = erc4626Vault.balanceOf(address(wallet));

        bytes memory result = _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (shares)));

        assertEq(abi.decode(abi.decode(result, (bytes)), (uint256)), received);
        assertEq(_feesCollected(address(usdc)), expectedFee);
        assertEq(usdc.balanceOf(address(wallet)), received - expectedFee);
    }

    function testERC4626DonationInflationCannotMintZeroShares() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fund(address(usdc), address(this), 1 + 1_000_000e6);
        usdc.approve(address(erc4626Vault), 1);
        erc4626Vault.deposit(1, address(this));
        usdc.transfer(address(erc4626Vault), 1_000_000e6);
        _fundWallet(wallet, address(usdc), 1_000e6);
        bytes memory data = abi.encodeCall(erc4626Adapter.deposit, (1_000e6));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), data, abi.encodeWithSignature("Error(string)", "AWKERC4626Adapter: zero shares minted"));
    }

    function testCompoundV2RejectsDepositsThatWouldMintZeroShares() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        compoundV2Vault.addYield(1e18);
        _fundWallet(wallet, address(usdc), 1);
        bytes memory data = abi.encodeCall(compoundV2Adapter.deposit, (1));
        _executeExpectRevert(wallet, address(compoundV2Adapter), address(compoundV2Vault), data, abi.encodeWithSignature("Error(string)", "AWKCompoundV2Adapter: zero shares minted"));
    }

    function testAaveV3PartialAndFinalWithdrawalsChargeTheFullRealizedYield() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principal = 1_000e6;
        uint256 yieldAmount = 100e6;
        uint256 withdrawal = 550e6;
        _fundWallet(wallet, address(usdc), principal);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (principal)));
        aaveV3Vault.addYield(address(wallet), yieldAmount);
        _fund(address(usdc), address(aaveV3Vault), yieldAmount);

        uint256 releasedBasis = principal * withdrawal / (principal + yieldAmount);
        uint256 expectedPartialFee = (withdrawal - releasedBasis) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (withdrawal)));
        assertEq(_feesCollected(address(usdc)), expectedPartialFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), principal - releasedBasis);

        uint256 remainingShares = aaveV3Vault.balanceOf(address(wallet));
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (remainingShares)));
        assertEq(_feesCollected(address(usdc)), yieldAmount * YIELD_FEE_BPS / 10_000);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), principal + yieldAmount - yieldAmount * YIELD_FEE_BPS / 10_000);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), principal + yieldAmount - yieldAmount * YIELD_FEE_BPS / 10_000);
    }

    function testAaveV3InterleavesDepositsWithdrawalsAndYieldWithoutLosingCostBasis() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 firstDeposit = 500e6;
        uint256 secondDeposit = 1_000e6;
        uint256 firstYield = 50e6;
        uint256 firstWithdrawal = 275e6;
        uint256 secondYield = 127e6;
        _fundWallet(wallet, address(usdc), firstDeposit + secondDeposit);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (firstDeposit)));
        aaveV3Vault.addYield(address(wallet), firstYield);
        _fund(address(usdc), address(aaveV3Vault), firstYield);

        uint256 firstReleasedBasis = firstDeposit * firstWithdrawal / (firstDeposit + firstYield);
        uint256 firstFee = (firstWithdrawal - firstReleasedBasis) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (firstWithdrawal)));
        assertEq(_feesCollected(address(usdc)), firstFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), firstDeposit - firstReleasedBasis);

        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (secondDeposit)));
        aaveV3Vault.addYield(address(wallet), secondYield);
        _fund(address(usdc), address(aaveV3Vault), secondYield);
        uint256 remaining = aaveV3Vault.balanceOf(address(wallet));
        uint256 totalDeposited = firstDeposit + secondDeposit;
        uint256 expectedTotalFee = (firstYield + secondYield) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (remaining)));

        assertEq(_feesCollected(address(usdc)), expectedTotalFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), totalDeposited + firstYield + secondYield - expectedTotalFee);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), totalDeposited + firstYield + secondYield - expectedTotalFee);
    }

    function testAaveV3GiftedRebasingSharesAreChargedOnWithdrawal() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 giftedShares = 10e6;
        uint256 withdrawal = 6e6;
        aaveV3Vault.addYield(address(wallet), giftedShares);
        _fund(address(usdc), address(aaveV3Vault), giftedShares);
        uint256 expectedFee = withdrawal * YIELD_FEE_BPS / 10_000;

        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (withdrawal)));

        assertEq(_feesCollected(address(usdc)), expectedFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), 0);
        assertEq(aaveV3Vault.balanceOf(address(wallet)), giftedShares - withdrawal);
        assertEq(usdc.balanceOf(address(wallet)), withdrawal - expectedFee);
    }

    function testAaveV3ManySmallWithdrawalsSettleTheSameTotalYieldFee() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principal = 1_000e6;
        uint256 yieldAmount = 100e6;
        uint256 withdrawal = 110e6;
        _fundWallet(wallet, address(usdc), principal);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (principal)));
        aaveV3Vault.addYield(address(wallet), yieldAmount);
        _fund(address(usdc), address(aaveV3Vault), yieldAmount);

        for (uint256 i; i < 10; ++i) {
            _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (withdrawal)));
        }

        uint256 expectedFee = yieldAmount * YIELD_FEE_BPS / 10_000;
        assertApproxEqAbs(_feesCollected(address(usdc)), expectedFee, 10);
        assertApproxEqAbs(vaultYieldFeeModule.costBasis(address(wallet), address(aaveV3Vault)), 0, 10);
        assertEq(aaveV3Vault.balanceOf(address(wallet)), 0);
    }

    function testAaveV3VeryLargeRebaseCannotChargeMoreThanWithdrawnAssets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principal = 10e6;
        uint256 yieldAmount = 10_000e6;
        uint256 withdrawal = 5e6;
        _fundWallet(wallet, address(usdc), principal);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (principal)));
        aaveV3Vault.addYield(address(wallet), yieldAmount);
        _fund(address(usdc), address(aaveV3Vault), yieldAmount);

        uint256 heldBefore = principal + yieldAmount;
        uint256 releasedBasis = principal * withdrawal / heldBefore;
        uint256 expectedFee = Math.mulDiv(withdrawal - releasedBasis, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (withdrawal)));

        assertEq(_feesCollected(address(usdc)), expectedFee);
        assertLe(expectedFee, withdrawal);
        assertEq(usdc.balanceOf(address(wallet)), withdrawal - expectedFee);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), withdrawal - expectedFee);
    }

    function testCompoundV2ExchangeRateAccrualPricesSharesAndSettlesYieldFees() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principalPerDeposit = 1_000e6;
        _fundWallet(wallet, address(usdc), 2 * principalPerDeposit);
        bytes memory firstDeposit = _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.deposit, (principalPerDeposit)));
        (uint256 firstShares,) = abi.decode(abi.decode(firstDeposit, (bytes)), (uint256, uint256));

        uint256 yieldAmount = principalPerDeposit / 2;
        compoundV2Vault.addYield(5_000);
        _fund(address(usdc), address(compoundV2Vault), yieldAmount);
        bytes memory secondDeposit = _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.deposit, (principalPerDeposit)));
        (uint256 secondShares, uint256 assetsDeposited) = abi.decode(abi.decode(secondDeposit, (bytes)), (uint256, uint256));
        assertLt(secondShares, firstShares);
        assertEq(assetsDeposited, principalPerDeposit);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV2Vault)), 2 * principalPerDeposit);

        uint256 allShares = compoundV2Vault.balanceOf(address(wallet));
        uint256 expectedAssetsOut = allShares * compoundV2Vault.exchangeRateCurrent() / 1e18;
        uint256 expectedYield = expectedAssetsOut - 2 * principalPerDeposit;
        uint256 expectedFee = Math.mulDiv(expectedYield, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        bytes memory withdrawal = _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.withdraw, (allShares)));
        assertEq(_decodeUint(withdrawal), expectedAssetsOut);
        assertEq(_feesCollected(address(usdc)), expectedFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV2Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), expectedAssetsOut - expectedFee);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), expectedAssetsOut - expectedFee);
    }

    function testCompoundV2UntrackedTransferredSharesAreChargedWhenRedeemed() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address depositor = makeAddr("external cToken depositor");
        uint256 suppliedAssets = 50_000e6;
        uint256 redeemedAssets = 1_000e6;
        _fund(address(usdc), depositor, suppliedAssets);
        vm.startPrank(depositor);
        usdc.approve(address(compoundV2Vault), suppliedAssets);
        compoundV2Vault.mint(suppliedAssets);
        compoundV2Vault.transfer(address(wallet), compoundV2Vault.balanceOf(depositor));
        vm.stopPrank();

        uint256 shares = redeemedAssets * 1e18 / compoundV2Vault.exchangeRateCurrent();
        uint256 expectedFee = redeemedAssets * YIELD_FEE_BPS / 10_000;
        bytes memory withdrawal = _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.withdraw, (shares)));
        assertEq(_decodeUint(withdrawal), redeemedAssets);
        assertEq(usdc.balanceOf(address(wallet)), redeemedAssets - expectedFee);
        assertEq(_feesCollected(address(usdc)), expectedFee);
        assertGt(compoundV2Vault.balanceOf(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), redeemedAssets - expectedFee);
    }

    function testCompoundV2NativeRedemptionsReturnWETHToTheOwner() public {
        MockWETH nativeWeth = new MockWETH();
        MockCNativeToken nativeMarket = new MockCNativeToken(payable(address(nativeWeth)), "Native mWETH", "mWETH");
        vaultRegistry.setTargetAdapter(address(nativeMarket), address(compoundV2Adapter));
        AgentWallet wallet = _createWalletForAsset(owner, 1, address(nativeWeth));
        uint256 depositAmount = 10e18;
        vm.deal(address(this), depositAmount);
        nativeWeth.deposit{value: depositAmount}();
        nativeWeth.transfer(address(wallet), depositAmount);
        _execute(wallet, address(compoundV2Adapter), address(nativeMarket), abi.encodeCall(compoundV2Adapter.deposit, (depositAmount)));

        uint256 partialShares = 4e18 * 1e18 / nativeMarket.exchangeRateCurrent();
        bytes memory partialWithdrawal = _execute(wallet, address(compoundV2Adapter), address(nativeMarket), abi.encodeCall(compoundV2Adapter.withdraw, (partialShares)));
        assertEq(_decodeUint(partialWithdrawal), 4e18);
        assertEq(nativeWeth.balanceOf(address(wallet)), 4e18);
        assertEq(address(wallet).balance, 0);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(nativeMarket)), 6e18);

        uint256 remainingShares = nativeMarket.balanceOf(address(wallet));
        bytes memory finalWithdrawal = _execute(wallet, address(compoundV2Adapter), address(nativeMarket), abi.encodeCall(compoundV2Adapter.withdraw, (remainingShares)));
        assertEq(_decodeUint(finalWithdrawal), 6e18);
        assertEq(nativeWeth.balanceOf(address(wallet)), depositAmount);
        assertEq(address(wallet).balance, 0);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(nativeMarket)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(nativeWeth));
        assertEq(nativeWeth.balanceOf(owner), depositAmount);
    }

    function testCompoundV3PartialWithdrawalsChargeOnlyRealizedYield() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 principal = 1_000e6;
        uint256 yieldAmount = 100e6;
        uint256 withdrawal = 550e6;
        _fundWallet(wallet, address(usdc), principal);
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (principal)));
        compoundV3Market.addYield(address(wallet), yieldAmount);
        _fund(address(usdc), address(compoundV3Market), yieldAmount);

        uint256 releasedBasis = principal * withdrawal / (principal + yieldAmount);
        uint256 expectedPartialFee = (withdrawal - releasedBasis) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (withdrawal)));
        assertEq(_feesCollected(address(usdc)), expectedPartialFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV3Market)), principal - releasedBasis);

        uint256 remainingBalance = compoundV3Market.balanceOf(address(wallet));
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (remainingBalance)));
        assertEq(_feesCollected(address(usdc)), yieldAmount * YIELD_FEE_BPS / 10_000);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV3Market)), 0);
        assertEq(usdc.balanceOf(address(wallet)), principal + yieldAmount - yieldAmount * YIELD_FEE_BPS / 10_000);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), principal + yieldAmount - yieldAmount * YIELD_FEE_BPS / 10_000);
    }

    function testCompoundV3UntrackedBalanceIsYieldEvenAfterTrackedDeposits() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 giftedBalance = 500e6;
        uint256 firstWithdrawal = 250e6;
        uint256 trackedDeposit = 1_000e6;
        compoundV3Market.addYield(address(wallet), giftedBalance);
        _fund(address(usdc), address(compoundV3Market), giftedBalance);
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (firstWithdrawal)));
        assertEq(_feesCollected(address(usdc)), firstWithdrawal * YIELD_FEE_BPS / 10_000);

        _fundWallet(wallet, address(usdc), trackedDeposit);
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (trackedDeposit)));
        assertEq(compoundV3Market.balanceOf(address(wallet)), 250e6 + trackedDeposit);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV3Market)), trackedDeposit);
        uint256 remaining = compoundV3Market.balanceOf(address(wallet));
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (remaining)));

        assertEq(_feesCollected(address(usdc)), 2 * firstWithdrawal * YIELD_FEE_BPS / 10_000);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(compoundV3Market)), 0);
        assertEq(usdc.balanceOf(address(wallet)), trackedDeposit + giftedBalance - 2 * firstWithdrawal * YIELD_FEE_BPS / 10_000);
    }

    function testCompoundV3WithdrawalCannotBorrowAgainstThirdPartyCollateral() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 suppliedBalance = 1_000e6;
        uint256 requestedWithdrawal = 1_500e6;
        uint256 thirdPartyCollateral = 1_000e6;
        _fundWallet(wallet, address(usdc), suppliedBalance);
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (suppliedBalance)));
        _fund(address(usdc), address(compoundV3Market), requestedWithdrawal - suppliedBalance);
        address collateralProvider = makeAddr("collateral provider");
        vm.prank(collateralProvider);
        compoundV3Market.supplyCollateralTo(address(wallet), thirdPartyCollateral);
        assertEq(compoundV3Market.collateralOf(address(wallet)), thirdPartyCollateral);

        bytes memory withdrawal = _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (requestedWithdrawal)));
        assertEq(_decodeUint(withdrawal), suppliedBalance);
        assertEq(usdc.balanceOf(address(wallet)), suppliedBalance);
        assertEq(compoundV3Market.balanceOf(address(wallet)), 0);
        assertEq(compoundV3Market.borrowBalanceOf(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), suppliedBalance);
    }

    function testCompoundV3WithdrawalWithNoSuppliedBalanceRevertsZeroAmount() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        bytes memory data = abi.encodeCall(compoundV3Adapter.withdraw, (1e6));
        _executeExpectRevert(wallet, address(compoundV3Adapter), address(compoundV3Market), data, abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        assertEq(compoundV3Market.borrowBalanceOf(address(wallet)), 0);
    }

    function testEightDecimalBaseAssetWorksAcrossAllVaultAdapters() public {
        _testBaseAssetAcrossAllVaultAdapters(8);
    }

    function testEighteenDecimalBaseAssetWorksAcrossAllVaultAdapters() public {
        _testBaseAssetAcrossAllVaultAdapters(18);
    }

    function _testBaseAssetAcrossAllVaultAdapters(uint8 decimals_) private {
        MockERC20WithDecimals asset = new MockERC20WithDecimals("Variant Base Asset", "VAR", decimals_);
        MockERC4626 vault = new MockERC4626(address(asset), "Variant Vault", "vVault");
        MockAaveV3Pool pool = new MockAaveV3Pool(address(asset));
        MockAToken aToken = MockAToken(pool.aToken());
        MockCToken cToken = new MockCToken(address(asset), "Variant cToken", "vcToken");
        MockCompoundV3Comet comet = new MockCompoundV3Comet(address(asset));
        vaultRegistry.setTargetAdapter(address(vault), address(erc4626Adapter));
        vaultRegistry.setTargetAdapter(address(aToken), address(aaveV3Adapter));
        vaultRegistry.setTargetAdapter(address(cToken), address(compoundV2Adapter));
        vaultRegistry.setTargetAdapter(address(comet), address(compoundV3Adapter));
        AgentWallet wallet = _createWalletForAsset(owner, 1, address(asset));
        uint256 amountPerProtocol = 10 ** uint256(decimals_);
        uint256 yieldAmount = amountPerProtocol / 10;
        _fund(address(asset), address(wallet), 4 * amountPerProtocol);

        _execute(wallet, address(erc4626Adapter), address(vault), abi.encodeCall(erc4626Adapter.deposit, (amountPerProtocol)));
        _execute(wallet, address(aaveV3Adapter), address(aToken), abi.encodeCall(aaveV3Adapter.deposit, (amountPerProtocol)));
        _execute(wallet, address(compoundV2Adapter), address(cToken), abi.encodeCall(compoundV2Adapter.deposit, (amountPerProtocol)));
        _execute(wallet, address(compoundV3Adapter), address(comet), abi.encodeCall(compoundV3Adapter.deposit, (amountPerProtocol)));

        _fund(address(asset), address(vault), yieldAmount);
        aToken.addYield(address(wallet), yieldAmount);
        _fund(address(asset), address(aToken), yieldAmount);
        cToken.addYield(1_000);
        _fund(address(asset), address(cToken), yieldAmount);
        comet.addYield(address(wallet), yieldAmount);
        _fund(address(asset), address(comet), yieldAmount);

        _execute(wallet, address(erc4626Adapter), address(vault), abi.encodeCall(erc4626Adapter.withdraw, (amountPerProtocol)));
        _execute(wallet, address(aaveV3Adapter), address(aToken), abi.encodeCall(aaveV3Adapter.withdraw, (amountPerProtocol + yieldAmount)));
        _execute(wallet, address(compoundV2Adapter), address(cToken), abi.encodeCall(compoundV2Adapter.withdraw, (cToken.balanceOf(address(wallet)))));
        _execute(wallet, address(compoundV3Adapter), address(comet), abi.encodeCall(compoundV3Adapter.withdraw, (amountPerProtocol + yieldAmount)));

        uint256 feePerProtocol = yieldAmount * YIELD_FEE_BPS / 10_000;
        uint256 expectedOwnerBalance = 4 * (amountPerProtocol + yieldAmount) - 4 * feePerProtocol;
        assertEq(asset.decimals(), decimals_);
        assertEq(_feesCollected(address(asset)), 4 * feePerProtocol);
        assertEq(asset.balanceOf(address(wallet)), expectedOwnerBalance);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(asset));
        assertEq(asset.balanceOf(owner), expectedOwnerBalance);
    }

    function testExistingWalletUsesNewVaultRegistrationsAndLosesRemovedTargets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        MockERC4626 vault = new MockERC4626(address(usdc), "Late Vault", "lateVault");
        bytes memory data = abi.encodeCall(erc4626Adapter.deposit, (1_000e6));
        bytes memory notRegistered = abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter));
        vm.expectRevert(notRegistered);
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(vault), data);

        vaultRegistry.setTargetAdapter(address(vault), address(erc4626Adapter));
        _fundWallet(wallet, address(usdc), 1_000e6);
        _execute(wallet, address(erc4626Adapter), address(vault), data);
        assertEq(vault.balanceOf(address(wallet)), 1_000e6);

        vaultRegistry.removeTarget(address(vault));
        vm.expectRevert(notRegistered);
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(vault), data);
        assertEq(vault.balanceOf(address(wallet)), 1_000e6);
    }

    function testERC4626PositionsCanBeDistributedAndConsolidatedAcrossVaults() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        MockERC4626 secondVault = new MockERC4626(address(usdc), "Second Vault", "v2");
        MockERC4626 thirdVault = new MockERC4626(address(usdc), "Third Vault", "v3");
        vaultRegistry.setTargetAdapter(address(secondVault), address(erc4626Adapter));
        vaultRegistry.setTargetAdapter(address(thirdVault), address(erc4626Adapter));
        _fundWallet(wallet, address(usdc), 9_000e6);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (3_000e6)));
        _execute(wallet, address(erc4626Adapter), address(secondVault), abi.encodeCall(erc4626Adapter.deposit, (3_000e6)));
        _execute(wallet, address(erc4626Adapter), address(thirdVault), abi.encodeCall(erc4626Adapter.deposit, (3_000e6)));
        assertEq(erc4626Vault.balanceOf(address(wallet)), 3_000e6);
        assertEq(secondVault.balanceOf(address(wallet)), 3_000e6);
        assertEq(thirdVault.balanceOf(address(wallet)), 3_000e6);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (3_000e6)));
        _execute(wallet, address(erc4626Adapter), address(secondVault), abi.encodeCall(erc4626Adapter.withdraw, (3_000e6)));
        _execute(wallet, address(erc4626Adapter), address(thirdVault), abi.encodeCall(erc4626Adapter.deposit, (6_000e6)));
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
        assertEq(secondVault.balanceOf(address(wallet)), 0);
        assertEq(thirdVault.balanceOf(address(wallet)), 9_000e6);

        _execute(wallet, address(erc4626Adapter), address(thirdVault), abi.encodeCall(erc4626Adapter.withdraw, (9_000e6)));
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), 9_000e6);
    }

    function testVaultWalletsKeepPositionsIsolatedAndOwnersWithdrawTheirAssets() public {
        address secondOwner = makeAddr("second owner");
        AgentWallet firstWallet = _createVaultWallet(owner, 1);
        AgentWallet secondWallet = _createVaultWallet(secondOwner, 1);
        _fundWallet(firstWallet, address(usdc), 5_000e6);
        _fundWallet(secondWallet, address(usdc), 3_000e6);
        _execute(firstWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (5_000e6)));
        _execute(secondWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (3_000e6)));

        _execute(firstWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (2_000e6)));
        assertEq(erc4626Vault.balanceOf(address(firstWallet)), 3_000e6);
        assertEq(erc4626Vault.balanceOf(address(secondWallet)), 3_000e6);
        vm.prank(owner);
        firstWallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), 2_000e6);

        _execute(secondWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (3_000e6)));
        vm.prank(secondOwner);
        secondWallet.withdrawAllAssetToUser(secondOwner, address(usdc));
        assertEq(usdc.balanceOf(secondOwner), 3_000e6);
        assertEq(erc4626Vault.balanceOf(address(firstWallet)), 3_000e6);
        assertEq(erc4626Vault.balanceOf(address(secondWallet)), 0);
    }

    function testVaultWalletMovesPositionAcrossProtocolsAndConsolidatesToBaseAsset() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(usdc), 9_000e6);
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (3_000e6)));
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.deposit, (3_000e6)));
        _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.deposit, (3_000e6)));
        assertEq(aaveV3Vault.balanceOf(address(wallet)), 3_000e6);
        assertEq(compoundV3Market.balanceOf(address(wallet)), 3_000e6);
        assertGt(compoundV2Vault.balanceOf(address(wallet)), 0);

        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.withdraw, (3_000e6)));
        _execute(wallet, address(compoundV3Adapter), address(compoundV3Market), abi.encodeCall(compoundV3Adapter.withdraw, (3_000e6)));
        _execute(wallet, address(compoundV2Adapter), address(compoundV2Vault), abi.encodeCall(compoundV2Adapter.withdraw, (compoundV2Vault.balanceOf(address(wallet)))));
        assertEq(aaveV3Vault.balanceOf(address(wallet)), 0);
        assertEq(compoundV3Market.balanceOf(address(wallet)), 0);
        assertEq(compoundV2Vault.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 9_000e6);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (9_000e6)));
        assertEq(erc4626Vault.balanceOf(address(wallet)), 9_000e6);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (9_000e6)));
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), 9_000e6);
    }
}
