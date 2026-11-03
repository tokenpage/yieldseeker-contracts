// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerCompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMoonwellMarket {
    function mint(uint256 amount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
}

contract MoonwellCompoundV2ForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant MWETH = 0x628ff693426583D9a7FB391E54366292F509D457;
    address internal constant MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;

    function test_MoonwellUSDC_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MUSDC, USDC, 6, 1e6);
    }

    function test_MoonwellCbBTC_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MCBBTC, CBBTC, 8, 100_000);
    }

    function test_MoonwellWETH_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MWETH, WETH, 18, 1e15);
    }

    function _testMarket(address marketAddress, address assetAddress, uint8 expectedDecimals, uint256 depositAmount) internal {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(assetAddress);
        IMoonwellMarket market = IMoonwellMarket(marketAddress);
        assertEq(asset.decimals(), expectedDecimals, "Unexpected underlying decimals");

        AgentWallet wallet = _createVaultWallet(assetAddress, 1);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();
        _registerAdapter(address(adapter), marketAddress);
        if (marketAddress == MUSDC) {
            deal(assetAddress, address(this), depositAmount);
            asset.approve(marketAddress, depositAmount);
            assertEq(market.mint(depositAmount), 0, "Moonwell liquidity mint failed");
        }
        deal(assetAddress, address(wallet), depositAmount);

        bytes memory depositResult = _execute(wallet, address(adapter), marketAddress, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 shares = abi.decode(abi.decode(depositResult, (bytes)), (uint256));
        assertGt(shares, 0, "Deposit returned no cToken shares");
        uint256 liveDepositBalanceBefore = market.balanceOfUnderlying(address(wallet));
        uint256 exchangeRate = market.exchangeRateCurrent();
        uint256 totalVaultBalanceBefore = (shares * exchangeRate) / 1e18;
        assertEq(liveDepositBalanceBefore, totalVaultBalanceBefore, "Live Compound V2 conversion mismatch");

        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 heldShares = market.balanceOf(address(wallet));
        uint256 liveBalanceBefore = market.balanceOfUnderlying(address(wallet));
        exchangeRate = market.exchangeRateCurrent();
        totalVaultBalanceBefore = (heldShares * exchangeRate) / 1e18;
        assertEq(liveBalanceBefore, totalVaultBalanceBefore, "Live Compound V2 conversion mismatch");

        uint256 feeCollectorBalanceBefore = asset.balanceOf(feeCollector);
        bytes memory withdrawResult = _execute(wallet, address(adapter), marketAddress, abi.encodeWithSelector(adapter.withdraw.selector, heldShares));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertApproxEqAbs(assetsReceived, liveBalanceBefore, 1, "Full redemption must return the live underlying balance");
        assertEq(market.balanceOf(address(wallet)), 0, "All redeemed reward shares should leave the wallet");
        uint256 expectedFee = assetsReceived > depositAmount ? Math.mulDiv(assetsReceived - depositAmount, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil) : 0;
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), marketAddress), 0, "Cost basis should clear after withdrawal");
        assertEq(asset.balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee, "Withdrawal fee should be paid immediately");
        uint256 ownerBalanceBefore = asset.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, assetAddress);
        assertEq(asset.balanceOf(owner) - ownerBalanceBefore, assetsReceived - expectedFee);
        assertEq(asset.balanceOf(address(wallet)), 0);
    }

    function test_MoonwellWETH_PartialWithdrawalUnwrapsNativeETHToWETH() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata weth = IERC20Metadata(WETH);
        IMoonwellMarket market = IMoonwellMarket(MWETH);

        AgentWallet wallet = _createVaultWallet(WETH, 1);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();
        _registerAdapter(address(adapter), MWETH);

        uint256 depositAmount = 2e15;
        deal(WETH, address(wallet), depositAmount);

        _execute(wallet, address(adapter), MWETH, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 shares = market.balanceOf(address(wallet));
        uint256 sharesToWithdraw = shares / 2;
        uint256 exchangeRate = market.exchangeRateCurrent();
        uint256 expectedAssets = (sharesToWithdraw * exchangeRate) / 1e18;
        uint256 releasedBasis = (depositAmount * sharesToWithdraw) / shares;
        uint256 feeCollectorBalanceBefore = weth.balanceOf(feeCollector);
        assertGt(sharesToWithdraw, 0, "Partial withdrawal must redeem cToken shares");
        assertEq(address(wallet).balance, 0, "Wallet should not hold native ETH before withdrawal");

        bytes memory withdrawResult = _execute(wallet, address(adapter), MWETH, abi.encodeWithSelector(adapter.withdraw.selector, sharesToWithdraw));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));

        assertApproxEqAbs(assetsReceived, expectedAssets, 1, "Should report assets received for redeemed shares");
        uint256 expectedYield = assetsReceived > releasedBasis ? assetsReceived - releasedBasis : 0;
        uint256 expectedFee = Math.mulDiv(expectedYield, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        assertApproxEqAbs(weth.balanceOf(address(wallet)), assetsReceived - expectedFee, 1, "Native ETH from live Moonwell mWETH must be wrapped back into WETH");
        assertEq(address(wallet).balance, 0, "Wallet must not be left holding native ETH after withdrawal");
        uint256 remainingShares = market.balanceOf(address(wallet));
        assertGt(remainingShares, 0, "Remaining mWETH position should still be tracked after a partial withdrawal");
        uint256 costBasis = vaultYieldFeeModule.costBasis(address(wallet), MWETH);
        assertGt(costBasis, 0, "Remaining cost basis should still be tracked after a partial withdrawal");
        assertEq(weth.balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee);
        uint256 ownerBalanceBefore = weth.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, WETH);
        assertEq(weth.balanceOf(owner) - ownerBalanceBefore, assetsReceived - expectedFee);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }
}
