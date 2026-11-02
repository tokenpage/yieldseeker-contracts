// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAaveV3LendingAdapter} from "../../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter} from "../../../src/adapters/MerklAdapter.sol";
import {YieldSeekerMoonwellRewardAdapter} from "../../../src/adapters/MoonwellRewardAdapter.sol";
import {YieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockLendingAaveV3Pool} from "../../mocks/MockLendingMarkets.sol";
import {MockSwapAdapterPriceOracle} from "../../mocks/MockSwapAdapterPriceOracle.sol";
import {AdapterFeeSetup, AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {MockMerklDistributor} from "./MerklAdapter.t.sol";
import {IERC20Like, MockMoonwellComptroller} from "./MoonwellRewardAdapter.t.sol";
import {MockUniswapV3Router} from "./UniswapV3SwapAdapter.t.sol";
import {Test, console} from "forge-std/Test.sol";

contract FeeGasBenchmarkTest is Test {
    address private constant FEE_COLLECTOR = address(0xBEEF);
    uint256 private constant USDC = 1e6;
    uint256 private constant BORROW_AMOUNT = 100 * USDC;
    uint256 private constant COLLATERAL_AMOUNT = 1_000 * USDC;

    YieldSeekerFeeTracker private feeTracker;
    YieldSeekerBorrowFeeModule private borrowFees;
    AdapterWalletHarness private wallet;
    MockERC20 private baseAsset;
    MockERC20 private transferProbe;
    MockSwapAdapterPriceOracle private oracle;
    YieldSeekerERC4626Adapter private vaultAdapter;
    YieldSeekerMerklAdapter private merklAdapter;
    YieldSeekerMoonwellRewardAdapter private moonwellAdapter;
    YieldSeekerUniswapV3SwapAdapter private swapAdapter;
    YieldSeekerSwapSellPolicy private sellPolicy;
    MockERC4626 private vault;
    MockMerklDistributor private distributor;
    MockERC20 private wellToken;
    MockMoonwellComptroller private comptroller;
    MockUniswapV3Router private router;

    function setUp() public {
        vm.warp(10_000_000);
        baseAsset = new MockERC20("Mock USDC", "USDC");
        transferProbe = new MockERC20("Transfer Probe", "PROBE");
        transferProbe.mint(address(this), 2 * USDC);
        (feeTracker,) = AdapterFeeSetup.deploy(FEE_COLLECTOR, 10_000, 1_000);
        oracle = new MockSwapAdapterPriceOracle();
        borrowFees = new YieldSeekerBorrowFeeModule(feeTracker, oracle, 10_000);
        feeTracker.setFeeModule(BORROW_FEE, borrowFees);
        feeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 50})));
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        baseAsset.mint(address(wallet), 1_000_000 * USDC);
        vaultAdapter = new YieldSeekerERC4626Adapter();
        merklAdapter = new YieldSeekerMerklAdapter();
        vault = new MockERC4626(address(baseAsset), "Vault", "vUSDC");
        distributor = new MockMerklDistributor();
        baseAsset.mint(address(distributor), 1_000_000 * USDC);
        wellToken = new MockERC20("Moonwell", "WELL");
        moonwellAdapter = new YieldSeekerMoonwellRewardAdapter(address(wellToken));
        comptroller = new MockMoonwellComptroller(IERC20Like(address(wellToken)));
        wellToken.mint(address(comptroller), 1_000_000e18);
        comptroller.setRewardPerMarket(1e18);
        sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        sellPolicy.addSellableToken(address(wellToken));
        router = new MockUniswapV3Router();
        swapAdapter = new YieldSeekerUniswapV3SwapAdapter(address(router), address(sellPolicy), oracle, 100);
        baseAsset.mint(address(router), 1_000_000 * USDC);
    }

    function test_Deposit_ProductionMedianGas() public {
        uint256 amount = 106_110_000;
        uint256 gasPriceWei = 6_000_000;
        uint256 microDollars = (25_000 * gasPriceWei * 2_283 * 1_000_000) / 1_000_000_000_000_000_000;
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);
        MockERC4626 directVault = new MockERC4626(address(baseAsset), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        baseAsset.mint(directUser, amount);
        vm.prank(directUser);
        baseAsset.approve(address(directVault), type(uint256).max);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.deposit(amount, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        wallet.executeAdapter(address(vaultAdapter), address(vault), abi.encodeWithSelector(vaultAdapter.deposit.selector, amount));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR), collectorBefore);
        assertEq(wallet.yieldFeeModule().costBasis(address(wallet), address(vault)), amount);
        _logGas("Vault deposit $106.11", directGas, adapterGas, false);

        console.log("25k gas at 0.006 gwei and ETH $2,283 (micro-dollars):", microDollars);
    }

    function test_Withdraw_ProductionMedianGas() public {
        uint256 basis = 106_920_000;
        uint256 growth = 1_070_000;
        uint256 expectedFee = growth / 10;
        MockERC4626 directVault = new MockERC4626(address(baseAsset), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        baseAsset.mint(directUser, basis);
        vm.prank(directUser);
        baseAsset.approve(address(directVault), type(uint256).max);
        vm.prank(directUser);
        directVault.deposit(basis, directUser);
        baseAsset.mint(address(directVault), growth);
        wallet.executeAdapter(address(vaultAdapter), address(vault), abi.encodeWithSelector(vaultAdapter.deposit.selector, basis));
        baseAsset.mint(address(vault), growth);
        uint256 directShares = directVault.balanceOf(directUser);
        uint256 adapterShares = vault.balanceOf(address(wallet));
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.redeem(directShares, directUser, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        wallet.executeAdapter(address(vaultAdapter), address(vault), abi.encodeWithSelector(vaultAdapter.withdraw.selector, adapterShares));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBefore, expectedFee);
        assertEq(baseAsset.balanceOf(address(wallet)), 1_000_000 * USDC - basis + basis + growth - expectedFee);
        _logGas("Vault withdraw $107.99", directGas, adapterGas, true);
    }

    function test_Withdraw_ProductionP90Gas() public {
        uint256 basis = 4_987_130_000;
        uint256 growth = 49_870_000;
        uint256 expectedFee = growth / 10;
        MockERC4626 directVault = new MockERC4626(address(baseAsset), "Direct", "dUSDC");
        address directUser = address(0xDEAD);
        baseAsset.mint(directUser, basis);
        vm.prank(directUser);
        baseAsset.approve(address(directVault), type(uint256).max);
        vm.prank(directUser);
        directVault.deposit(basis, directUser);
        baseAsset.mint(address(directVault), growth);
        wallet.executeAdapter(address(vaultAdapter), address(vault), abi.encodeWithSelector(vaultAdapter.deposit.selector, basis));
        baseAsset.mint(address(vault), growth);
        uint256 directShares = directVault.balanceOf(directUser);
        uint256 adapterShares = vault.balanceOf(address(wallet));
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        directVault.redeem(directShares, directUser, directUser);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        wallet.executeAdapter(address(vaultAdapter), address(vault), abi.encodeWithSelector(vaultAdapter.withdraw.selector, adapterShares));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBefore, expectedFee);
        _logGas("Vault withdraw $5,037", directGas, adapterGas, true);
    }

    function test_MerklClaim_ProductionMedianGas() public {
        uint256 amount = 316_000;
        uint256 expectedFee = amount / 10;
        address directUser = address(0xDEAD);
        (address[] memory directUsers, address[] memory directTokens, uint256[] memory directAmounts, bytes32[][] memory directProofs) = _merklArgs(directUser, amount);
        (address[] memory walletUsers, address[] memory walletTokens, uint256[] memory walletAmounts, bytes32[][] memory walletProofs) = _merklArgs(address(wallet), amount);
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        distributor.claim(directUsers, directTokens, directAmounts, directProofs);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        wallet.executeAdapter(address(merklAdapter), address(distributor), abi.encodeWithSelector(merklAdapter.claim.selector, walletUsers, walletTokens, walletAmounts, walletProofs));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBefore, expectedFee);
        assertEq(wallet.yieldFeeModule().feesOwed(address(wallet)), 0);
        _logGas("Merkl USDC claim $0.316", directGas, adapterGas, true);
    }

    function test_MerklClaim_ProductionP10Gas() public {
        uint256 amount = 108_000;
        uint256 expectedFee = amount / 10;
        address directUser = address(0xDEAD);
        (address[] memory directUsers, address[] memory directTokens, uint256[] memory directAmounts, bytes32[][] memory directProofs) = _merklArgs(directUser, amount);
        (address[] memory walletUsers, address[] memory walletTokens, uint256[] memory walletAmounts, bytes32[][] memory walletProofs) = _merklArgs(address(wallet), amount);
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);

        vm.prank(directUser);
        uint256 directStart = gasleft();
        distributor.claim(directUsers, directTokens, directAmounts, directProofs);
        uint256 directGas = directStart - gasleft();

        uint256 adapterStart = gasleft();
        wallet.executeAdapter(address(merklAdapter), address(distributor), abi.encodeWithSelector(merklAdapter.claim.selector, walletUsers, walletTokens, walletAmounts, walletProofs));
        uint256 adapterGas = adapterStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBefore, expectedFee);
        assertEq(wallet.yieldFeeModule().feesOwed(address(wallet)), 0);
        _logGas("Merkl USDC claim $0.108", directGas, adapterGas, true);
    }

    function test_MoonwellClaimAndSwap_ProductionGas() public {
        uint256 wellAmount = 1e18;
        uint256 buyAmount = 100_000;
        uint256 expectedFee = buyAmount / 10;
        address directUser = address(0xDEAD);
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(0x1111);
        address[] memory routePath = new address[](2);
        routePath[0] = address(wellToken);
        routePath[1] = address(baseAsset);
        uint24[] memory routeFees = new uint24[](1);
        routeFees[0] = 3000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: routePath, fees: routeFees});
        IUniswapV3SwapRouter.ExactInputParams memory directParams =
            IUniswapV3SwapRouter.ExactInputParams({path: abi.encodePacked(address(wellToken), uint24(3000), address(baseAsset)), recipient: directUser, amountIn: wellAmount, amountOutMinimum: buyAmount});
        router.setBuyAmount(buyAmount);
        uint256 collectorBefore = baseAsset.balanceOf(FEE_COLLECTOR);
        uint256 walletBaseBeforeSwap = baseAsset.balanceOf(address(wallet));

        uint256 directClaimStart = gasleft();
        comptroller.claimReward(directUser, mTokens);
        uint256 directClaimGas = directClaimStart - gasleft();

        uint256 adapterClaimStart = gasleft();
        wallet.executeAdapter(address(moonwellAdapter), address(comptroller), abi.encodeWithSelector(moonwellAdapter.claimReward.selector, address(wallet), mTokens));
        uint256 adapterClaimGas = adapterClaimStart - gasleft();

        assertEq(wellToken.balanceOf(address(wallet)), wellAmount);
        assertEq(baseAsset.balanceOf(FEE_COLLECTOR), collectorBefore);
        assertEq(wallet.yieldFeeModule().feesOwed(address(wallet)), 0);
        _logGas("Moonwell WELL claim $0.10", directClaimGas, adapterClaimGas, false);

        vm.prank(directUser);
        wellToken.approve(address(router), type(uint256).max);
        vm.prank(directUser);
        uint256 directSwapStart = gasleft();
        router.exactInput(directParams);
        uint256 directSwapGas = directSwapStart - gasleft();

        uint256 adapterSwapStart = gasleft();
        wallet.executeAdapter(address(swapAdapter), address(router), abi.encodeWithSelector(swapAdapter.swap.selector, address(wellToken), address(baseAsset), route, wellAmount, buyAmount));
        uint256 adapterSwapGas = adapterSwapStart - gasleft();

        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBefore, expectedFee);
        assertEq(baseAsset.balanceOf(address(wallet)) - walletBaseBeforeSwap, buyAmount - expectedFee);
        _logGas("WELL-to-USDC swap $0.10", directSwapGas, adapterSwapGas, true);
    }

    function test_BorrowRepayWithdrawCollateral_ProductionGas() public {
        uint256 expectedFee = (BORROW_AMOUNT * 50) / 10_000;
        MockERC20 debtAsset = new MockERC20("Debt USDC", "dUSDC");
        MockERC20 aToken = new MockERC20("Collateral", "aUSDC");
        MockERC20 variableDebtToken = new MockERC20("Variable debt", "vdUSDC");
        MockLendingAaveV3Pool pool = new MockLendingAaveV3Pool();
        MockLendingAaveV3Pool directPool = new MockLendingAaveV3Pool();
        YieldSeekerAaveV3LendingAdapter adapter = new YieldSeekerAaveV3LendingAdapter();
        pool.setReserve(address(baseAsset), address(aToken), address(0));
        pool.setReserve(address(debtAsset), address(0), address(variableDebtToken));
        directPool.setReserve(address(baseAsset), address(aToken), address(0));
        directPool.setReserve(address(debtAsset), address(0), address(variableDebtToken));
        bytes memory market = abi.encode(address(pool), address(baseAsset), address(debtAsset), uint8(0));
        address directUser = address(0xD1EC7);
        baseAsset.mint(directUser, COLLATERAL_AMOUNT);
        baseAsset.burn(address(wallet), baseAsset.balanceOf(address(wallet)) - COLLATERAL_AMOUNT);
        wallet.executeAdapter(address(adapter), adapter.marketTarget(market), abi.encodeWithSelector(adapter.supplyCollateral.selector, market, COLLATERAL_AMOUNT));
        vm.prank(directUser);
        baseAsset.approve(address(directPool), COLLATERAL_AMOUNT);
        vm.prank(directUser);
        directPool.supply(address(baseAsset), COLLATERAL_AMOUNT, directUser, 0);

        vm.prank(directUser);
        uint256 directBorrowStart = gasleft();
        directPool.borrow(address(debtAsset), BORROW_AMOUNT, 2, 0, directUser);
        uint256 directBorrowGas = directBorrowStart - gasleft();

        uint256 adapterBorrowStart = gasleft();
        wallet.executeAdapter(address(adapter), adapter.marketTarget(market), abi.encodeWithSelector(adapter.borrow.selector, market, BORROW_AMOUNT));
        uint256 adapterBorrowGas = adapterBorrowStart - gasleft();
        _logGas("Aave V3 borrow $100", directBorrowGas, adapterBorrowGas, false);

        uint256 oneYearLater = vm.getBlockTimestamp() + 365 days;
        vm.warp(oneYearLater);
        vm.prank(directUser);
        debtAsset.approve(address(directPool), type(uint256).max);
        vm.prank(directUser);
        uint256 directRepayStart = gasleft();
        directPool.repay(address(debtAsset), type(uint256).max, 2, directUser);
        uint256 directRepayGas = directRepayStart - gasleft();

        uint256 collectorBeforeRepay = baseAsset.balanceOf(FEE_COLLECTOR);
        uint256 adapterRepayStart = gasleft();
        wallet.executeAdapter(address(adapter), adapter.marketTarget(market), abi.encodeWithSelector(adapter.repay.selector, market, type(uint256).max));
        uint256 adapterRepayGas = adapterRepayStart - gasleft();
        assertEq(baseAsset.balanceOf(FEE_COLLECTOR), collectorBeforeRepay);
        assertEq(borrowFees.feesOwed(address(wallet), address(debtAsset)), expectedFee);
        _logGas("Aave V3 repay after one year", directRepayGas, adapterRepayGas, false);

        vm.prank(directUser);
        uint256 directWithdrawStart = gasleft();
        directPool.withdraw(address(baseAsset), type(uint256).max, directUser);
        uint256 directWithdrawGas = directWithdrawStart - gasleft();

        uint256 adapterWithdrawStart = gasleft();
        wallet.executeAdapter(address(adapter), adapter.marketTarget(market), abi.encodeWithSelector(adapter.withdrawCollateral.selector, market, type(uint256).max));
        uint256 adapterWithdrawGas = adapterWithdrawStart - gasleft();
        assertEq(baseAsset.balanceOf(FEE_COLLECTOR) - collectorBeforeRepay, expectedFee);
        assertEq(borrowFees.feesOwed(address(wallet), address(debtAsset)), 0);
        _logGas("Aave V3 withdraw collateral and pay fee", directWithdrawGas, adapterWithdrawGas, true);
    }

    function _merklArgs(address user, uint256 amount) private view returns (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) {
        users = new address[](1);
        users[0] = user;
        tokens = new address[](1);
        tokens[0] = address(baseAsset);
        amounts = new uint256[](1);
        amounts[0] = amount;
        proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
    }

    function _logGas(string memory label, uint256 directGas, uint256 adapterGas, bool transferPaid) private {
        uint256 overhead = adapterGas - directGas;
        console.log(label);
        console.log("direct / adapter / overhead");
        console.log(directGas, adapterGas, overhead);
        if (transferPaid) {
            transferProbe.balanceOf(address(this));
            uint256 start = gasleft();
            bool transferred = transferProbe.transfer(FEE_COLLECTOR, 1);
            uint256 transferGas = start - gasleft();
            assertTrue(transferred);
            console.log("fee transfer gas / overhead share bps");
            console.log(transferGas, (transferGas * 10_000) / overhead);
        } else {
            console.log("fee transfer: none");
        }
    }
}
