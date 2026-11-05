// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockLendingAaveV3Pool} from "../mocks/MockLendingMarkets.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {console} from "forge-std/console.sol";

contract FeeGasBenchmarkIntegrationTest is IntegrationBase {
    uint256 private constant USDC = 1e6;
    uint256 private constant BORROW_AMOUNT = 100 * USDC;
    uint256 private constant COLLATERAL_AMOUNT = 1_000 * USDC;

    MockERC20 private transferProbe;

    function setUp() public override {
        super.setUp();
        transferProbe = new MockERC20("Transfer Probe", "PROBE");
        transferProbe.mint(address(this), 2);
    }

    function testDepositProductionMedianGas() public {
        uint256 amount = 106_110_000;
        uint256 gasPriceWei = 6_000_000;
        uint256 microDollars = (25_000 * gasPriceWei * 2_283 * 1_000_000) / 1_000_000_000_000_000_000;
        AgentWallet wallet = _createVaultWallet(owner, 0);
        _fundWallet(wallet, address(usdc), 1_000_000 * USDC);
        MockERC4626 directVault = new MockERC4626(address(usdc), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        usdc.mint(directUser, amount);
        vm.prank(directUser);
        usdc.approve(address(directVault), type(uint256).max);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.deposit(amount, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, amount));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), amount);
        _logGas("Vault deposit $106.11", 106_682, 205_448, 0, directGas, adapterGas, false);
        console.log("25k gas at 0.006 gwei and ETH $2,283 (micro-dollars):", microDollars);
    }

    function testWithdrawProductionMedianGas() public {
        uint256 basis = 106_920_000;
        uint256 growth = 1_070_000;
        uint256 expectedFee = growth / 10;
        AgentWallet wallet = _createVaultWallet(owner, 0);
        _fundWallet(wallet, address(usdc), 1_000_000 * USDC);
        MockERC4626 directVault = new MockERC4626(address(usdc), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        usdc.mint(directUser, basis);
        vm.prank(directUser);
        usdc.approve(address(directVault), type(uint256).max);
        vm.prank(directUser);
        directVault.deposit(basis, directUser);
        usdc.mint(address(directVault), growth);
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, basis));
        usdc.mint(address(erc4626Vault), growth);
        uint256 directShares = directVault.balanceOf(directUser);
        uint256 adapterShares = erc4626Vault.balanceOf(address(wallet));
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.redeem(directShares, directUser, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, adapterShares));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, expectedFee);
        assertEq(usdc.balanceOf(address(wallet)), 1_000_000 * USDC + growth - expectedFee);
        _logGas("Vault withdraw $107.99", 71_251, 149_854, 53_993, directGas, adapterGas, true);
    }

    function testWithdrawProductionP90Gas() public {
        uint256 basis = 4_987_130_000;
        uint256 growth = 49_870_000;
        uint256 expectedFee = growth / 10;
        AgentWallet wallet = _createVaultWallet(owner, 0);
        _fundWallet(wallet, address(usdc), 1_000_000 * USDC);
        MockERC4626 directVault = new MockERC4626(address(usdc), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        usdc.mint(directUser, basis);
        vm.prank(directUser);
        usdc.approve(address(directVault), type(uint256).max);
        vm.prank(directUser);
        directVault.deposit(basis, directUser);
        usdc.mint(address(directVault), growth);
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, basis));
        usdc.mint(address(erc4626Vault), growth);
        uint256 directShares = directVault.balanceOf(directUser);
        uint256 adapterShares = erc4626Vault.balanceOf(address(wallet));
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.redeem(directShares, directUser, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, adapterShares));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, expectedFee);
        _logGas("Vault withdraw $5,037", 71_274, 149_866, 53_993, directGas, adapterGas, true);
    }

    function testMerklClaimProductionMedianGas() public {
        _benchmarkMerklClaim(316_000, "Merkl USDC claim $0.316", 65_125, 137_824);
    }

    function testMerklClaimProductionP10Gas() public {
        _benchmarkMerklClaim(108_000, "Merkl USDC claim $0.108", 65_125, 137_824);
    }

    function testMoonwellClaimAndSwapProductionGas() public {
        AgentWallet wallet = _createVaultWallet(owner, 0);
        uint256 wellAmount = 1e18;
        uint256 buyAmount = 100_000;
        uint256 expectedFee = buyAmount / 10;
        address directUser = address(0xDEAD);
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(0x1111);
        address[] memory routePath = new address[](2);
        routePath[0] = address(wellToken);
        routePath[1] = address(usdc);
        uint24[] memory routeFees = new uint24[](1);
        routeFees[0] = 3_000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: routePath, fees: routeFees});
        IUniswapV3SwapRouter.ExactInputParams memory directParams =
            IUniswapV3SwapRouter.ExactInputParams({path: abi.encodePacked(address(wellToken), uint24(3_000), address(usdc)), recipient: directUser, amountIn: wellAmount, amountOutMinimum: buyAmount});
        moonwellComptroller.setRewardPerMarket(wellAmount);
        uniswapV3Router.setBuyAmount(buyAmount);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);
        uint256 walletBaseBeforeSwap = usdc.balanceOf(address(wallet));

        uint256 directClaimStart = gasleft();
        moonwellComptroller.claimReward(directUser, mTokens);
        uint256 directClaimGas = directClaimStart - gasleft();

        uint256 adapterClaimStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(moonwellRewardAdapter), address(moonwellComptroller), abi.encodeWithSelector(moonwellRewardAdapter.claimReward.selector, address(wallet), mTokens));
        uint256 adapterClaimGas = adapterClaimStart - gasleft();

        assertEq(wellToken.balanceOf(address(wallet)), wellAmount);
        assertEq(usdc.balanceOf(feeCollector), collectorBefore);
        _logGas("Moonwell WELL claim $0.10", 64_231, 116_067, 0, directClaimGas, adapterClaimGas, false);

        vm.prank(directUser);
        wellToken.approve(address(uniswapV3Router), type(uint256).max);
        vm.prank(directUser);
        uint256 directSwapStart = gasleft();
        uniswapV3Router.exactInput(directParams);
        uint256 directSwapGas = directSwapStart - gasleft();

        uint256 adapterSwapStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeWithSelector(uniswapV3SwapAdapter.swap.selector, address(wellToken), address(usdc), route, wellAmount, buyAmount));
        uint256 adapterSwapGas = adapterSwapStart - gasleft();

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, expectedFee);
        assertEq(usdc.balanceOf(address(wallet)) - walletBaseBeforeSwap, buyAmount - expectedFee);
        _logGas("WELL-to-USDC swap $0.10", 98_836, 204_195, 54_000, directSwapGas, adapterSwapGas, true);
    }

    function testBorrowRepayWithdrawCollateralProductionGas() public {
        uint256 expectedFee = (BORROW_AMOUNT * 50) / 10_000;
        AgentWallet wallet = _createBorrowWallet(owner, 0);
        MockERC20 debtAsset = new MockERC20("Debt USDC", "dUSDC");
        MockERC20 aToken = new MockERC20("Collateral", "aUSDC");
        MockERC20 variableDebtToken = new MockERC20("Variable debt", "vdUSDC");
        MockLendingAaveV3Pool pool = new MockLendingAaveV3Pool();
        MockLendingAaveV3Pool directPool = new MockLendingAaveV3Pool();
        pool.setReserve(address(usdc), address(aToken), address(0));
        pool.setReserve(address(debtAsset), address(0), address(variableDebtToken));
        MockERC20 directAToken = new MockERC20("Direct collateral", "daUSDC");
        MockERC20 directVariableDebtToken = new MockERC20("Direct variable debt", "dvdUSDC");
        directPool.setReserve(address(usdc), address(directAToken), address(0));
        directPool.setReserve(address(debtAsset), address(0), address(directVariableDebtToken));
        bytes memory market = abi.encode(address(pool), address(usdc), address(debtAsset), uint8(0));
        address marketTarget = aaveV3LendingAdapter.marketTarget(market);
        borrowRegistry.setTargetAdapter(marketTarget, address(aaveV3LendingAdapter));
        address directUser = address(0xD1EC7);
        usdc.mint(directUser, COLLATERAL_AMOUNT);
        _fundWallet(wallet, address(usdc), COLLATERAL_AMOUNT);

        vm.prank(operator);
        wallet.executeViaAdapter(address(aaveV3LendingAdapter), marketTarget, abi.encodeWithSelector(aaveV3LendingAdapter.supplyCollateral.selector, market, COLLATERAL_AMOUNT));
        vm.prank(directUser);
        usdc.approve(address(directPool), COLLATERAL_AMOUNT);
        vm.prank(directUser);
        directPool.supply(address(usdc), COLLATERAL_AMOUNT, directUser, 0);

        vm.prank(directUser);
        uint256 directBorrowStart = gasleft();
        directPool.borrow(address(debtAsset), BORROW_AMOUNT, 2, 0, directUser);
        uint256 directBorrowGas = directBorrowStart - gasleft();

        uint256 adapterBorrowStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(aaveV3LendingAdapter), marketTarget, abi.encodeWithSelector(aaveV3LendingAdapter.borrow.selector, market, BORROW_AMOUNT));
        uint256 adapterBorrowGas = adapterBorrowStart - gasleft();
        _logGas("Aave V3 borrow $100", 124_276, 218_423, 0, directBorrowGas, adapterBorrowGas, false);

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(directUser);
        debtAsset.approve(address(directPool), type(uint256).max);
        vm.prank(directUser);
        uint256 directRepayStart = gasleft();
        directPool.repay(address(debtAsset), type(uint256).max, 2, directUser);
        uint256 directRepayGas = directRepayStart - gasleft();

        uint256 collectorBeforeRepay = usdc.balanceOf(feeCollector);
        uint256 adapterRepayStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(aaveV3LendingAdapter), marketTarget, abi.encodeWithSelector(aaveV3LendingAdapter.repay.selector, market, type(uint256).max));
        uint256 adapterRepayGas = adapterRepayStart - gasleft();
        assertEq(usdc.balanceOf(feeCollector), collectorBeforeRepay);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedFee);
        _logGas("Aave V3 repay after one year", 101_220, 251_160, 0, directRepayGas, adapterRepayGas, false);

        vm.prank(directUser);
        uint256 directWithdrawStart = gasleft();
        directPool.withdraw(address(usdc), type(uint256).max, directUser);
        uint256 directWithdrawGas = directWithdrawStart - gasleft();

        uint256 adapterWithdrawStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(aaveV3LendingAdapter), marketTarget, abi.encodeWithSelector(aaveV3LendingAdapter.withdrawCollateral.selector, market, type(uint256).max));
        uint256 adapterWithdrawGas = adapterWithdrawStart - gasleft();
        assertEq(usdc.balanceOf(feeCollector) - collectorBeforeRepay, expectedFee);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        _logGas("Aave V3 withdraw collateral and pay fee", 78_885, 201_295, 54_001, directWithdrawGas, adapterWithdrawGas, true);
    }

    function _benchmarkMerklClaim(uint256 amount, string memory label, uint256 oldDirect, uint256 oldAdapter) private {
        AgentWallet wallet = _createVaultWallet(owner, amount);
        address directUser = address(0xDEAD);
        (address[] memory directUsers, address[] memory directTokens, uint256[] memory directAmounts, bytes32[][] memory directProofs) = _merklArgs(directUser, amount);
        (, address[] memory walletTokens, uint256[] memory walletAmounts, bytes32[][] memory walletProofs) = _merklArgs(address(wallet), amount);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        merklDistributor.claim(directUsers, directTokens, directAmounts, directProofs);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        vm.prank(operator);
        wallet.executeViaAdapter(address(merklAdapter), address(merklDistributor), abi.encodeCall(merklAdapter.claim, (walletTokens, walletAmounts, walletProofs)));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, amount / 10);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);
        _logGas(label, oldDirect, oldAdapter, 53_999, directGas, adapterGas, true);
    }

    function _merklArgs(address user, uint256 amount) private view returns (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) {
        users = new address[](1);
        users[0] = user;
        tokens = new address[](1);
        tokens[0] = address(usdc);
        amounts = new uint256[](1);
        amounts[0] = amount;
        proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
    }

    function _logGas(string memory label, uint256 oldDirect, uint256 oldAdapter, uint256 oldTransferGas, uint256 directGas, uint256 adapterGas, bool transferPaid) private {
        uint256 oldOverhead = oldAdapter - oldDirect;
        uint256 overhead = adapterGas - directGas;
        console.log(label);
        console.log("old direct / adapter / overhead");
        console.log(oldDirect, oldAdapter, oldOverhead);
        console.log("new direct / wallet.executeViaAdapter / overhead");
        console.log(directGas, adapterGas, overhead);
        if (transferPaid) {
            transferProbe.balanceOf(address(this));
            uint256 start = gasleft();
            bool transferred = transferProbe.transfer(feeCollector, 1);
            uint256 transferGas = start - gasleft();
            assertTrue(transferred);
            console.log("old fee transfer gas / overhead share bps");
            console.log(oldTransferGas, (oldTransferGas * 10_000) / oldOverhead);
            console.log("new fee transfer gas / overhead share bps");
            console.log(transferGas, (transferGas * 10_000) / overhead);
        } else {
            console.log("fee transfer: none");
        }
    }
}
