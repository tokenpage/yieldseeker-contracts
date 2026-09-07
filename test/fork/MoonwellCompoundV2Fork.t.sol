// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerCompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

interface IMoonwellMarket {
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
}

contract MoonwellCompoundV2ForkTest is Test {
    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
    }
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant MWETH = 0x628ff693426583D9a7FB391E54366292F509D457;
    address internal constant MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;

    uint256 internal constant FEE_RATE_BPS = 1000;

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

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(FEE_RATE_BPS, address(this));
        AdapterWalletHarness wallet = new AdapterWalletHarness(asset, feeTracker);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();
        deal(assetAddress, address(wallet), depositAmount);

        bytes memory depositResult = wallet.executeAdapter(address(adapter), marketAddress, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 shares = abi.decode(abi.decode(depositResult, (bytes)), (uint256));
        assertGt(shares, 0, "Deposit returned no cToken shares");
        uint256 liveBalanceBefore = market.balanceOfUnderlying(address(wallet));
        uint256 exchangeRate = market.exchangeRateCurrent();
        uint256 totalVaultBalanceBefore = (shares * exchangeRate) / 1e18;
        assertEq(liveBalanceBefore, totalVaultBalanceBefore, "Live Compound V2 conversion mismatch");

        uint256 rewardTokenAmount = shares / 10;
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(marketAddress, rewardTokenAmount);

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), marketAddress, abi.encodeWithSelector(adapter.withdraw.selector, liveBalanceBefore));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, liveBalanceBefore, "Withdrawal amount must match requested underlying amount");
        uint256 feeTokenOwed = (rewardTokenAmount * FEE_RATE_BPS) / 10_000;
        uint256 feeInBaseAsset = (feeTokenOwed * exchangeRate) / 1e18;
        if (feeInBaseAsset > assetsReceived) feeInBaseAsset = assetsReceived;
        uint256 netAssets = assetsReceived - feeInBaseAsset;
        uint256 expectedProfitFee = netAssets > depositAmount ? ((netAssets - depositAmount) * FEE_RATE_BPS) / 10_000 : 0;
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), marketAddress), 0, "Cost basis should clear after withdrawal");
        assertEq(feeTracker.agentVaultShares(address(wallet), marketAddress), 0, "Tracked shares should clear after withdrawal");
        assertEq(feeTracker.agentFeesCharged(address(wallet)), feeInBaseAsset + expectedProfitFee, "Live fee conversion mismatch");
    }

    function test_MoonwellWETH_PartialWithdrawalUnwrapsNativeETHToWETH() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata weth = IERC20Metadata(WETH);
        IMoonwellMarket market = IMoonwellMarket(MWETH);

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(FEE_RATE_BPS, address(this));
        AdapterWalletHarness wallet = new AdapterWalletHarness(weth, feeTracker);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();

        uint256 depositAmount = 2e15;
        uint256 withdrawAmount = 8e14;
        deal(WETH, address(wallet), depositAmount);

        wallet.executeAdapter(address(adapter), MWETH, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        assertEq(address(wallet).balance, 0, "Wallet should not hold native ETH before withdrawal");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), MWETH, abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));

        assertEq(assetsReceived, withdrawAmount, "Should report the requested underlying amount");
        assertEq(weth.balanceOf(address(wallet)), withdrawAmount, "Native ETH from live Moonwell mWETH must be wrapped back into WETH");
        assertEq(address(wallet).balance, 0, "Wallet must not be left holding native ETH after withdrawal");
        assertGt(market.balanceOf(address(wallet)), 0, "Remaining mWETH position should still be tracked after a partial withdrawal");
        assertGt(feeTracker.agentVaultCostBasis(address(wallet), MWETH), 0, "Remaining cost basis should still be tracked after a partial withdrawal");
    }
}
