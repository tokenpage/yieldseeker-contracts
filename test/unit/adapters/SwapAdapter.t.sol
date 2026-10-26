// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../../src/PriceOracle.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../../src/adapters/AaveV3LendingAdapter.sol";
import {AssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {SwapBelowOraclePrice} from "../../../src/adapters/SwapAdapter.sol";
import {SellTokenNotAllowed, YieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterExecutionFailed} from "../../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {VAULT_FEE} from "../../../src/fees/VaultFeeModule.sol";
import {MockERC20, MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockLendingAaveV3Pool} from "../../mocks/MockLendingMarkets.sol";
import {MockLendingPriceFeed} from "../../mocks/MockLendingPriceFeed.sol";
import {MockLendingSwapRouter} from "../../mocks/MockLendingSwapRouter.sol";
import {Test} from "forge-std/Test.sol";

contract SwapAdapterTest is Test {
    bytes32 private constant AGENT_PROFILE = keccak256("borrow");
    address private constant OWNER = address(0xA11CE);
    address private constant OPERATOR = address(0xB0B);
    address private constant FEE_COLLECTOR = address(0xFEE);
    uint256 private constant SLIPPAGE_BPS = 100;

    YieldSeekerAgentWalletFactory private factory;
    YieldSeekerAgentWalletV3 private wallet;
    YieldSeekerAdapterRegistry private registry;
    YieldSeekerFeeTracker private feeTracker;
    YieldSeekerBorrowFeeModule private feeModule;
    YieldSeekerPriceOracle private oracle;
    YieldSeekerSwapSellPolicy private sellPolicy;
    YieldSeekerUniswapV3SwapAdapter private swapAdapter;
    YieldSeekerAaveV3LendingAdapter private lendingAdapter;
    MockLendingSwapRouter private router;
    MockLendingAaveV3Pool private aavePool;
    MockERC20WithDecimals private weth;
    MockERC20WithDecimals private usdc;
    MockERC20WithDecimals private reward;
    MockERC20WithDecimals private unsupportedReward;
    MockERC20 private aWeth;
    MockERC20 private variableDebtUsdc;
    MockLendingPriceFeed private wethFeed;
    MockLendingPriceFeed private usdcFeed;

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockERC20WithDecimals("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        reward = new MockERC20WithDecimals("Reward Token", "RWD", 18);
        unsupportedReward = new MockERC20WithDecimals("Unsupported Reward", "BAD", 18);

        uint256 now_ = vm.getBlockTimestamp();
        MockLendingPriceFeed sequencerFeed = new MockLendingPriceFeed(0, 0);
        sequencerFeed.setRoundData(0, now_ - 2 days, now_ - 2 days);
        oracle = new YieldSeekerPriceOracle(address(this), address(this), IPriceFeed(address(sequencerFeed)));
        wethFeed = new MockLendingPriceFeed(8, int256(2_000e8));
        usdcFeed = new MockLendingPriceFeed(8, int256(1e8));
        oracle.setSource(address(weth), IPriceFeed(address(wethFeed)), 1 days);
        oracle.setSource(address(usdc), IPriceFeed(address(usdcFeed)), 1 days);

        feeTracker = new YieldSeekerFeeTracker(address(this), address(this), FEE_COLLECTOR, 10_000, 1_000);
        feeModule = new YieldSeekerBorrowFeeModule(feeTracker, 10_000);
        feeTracker.addFeeModule(BORROW_FEE, feeModule);
        feeTracker.setPlanRate(0, BORROW_FEE, 50);
        factory = new YieldSeekerAgentWalletFactory(address(this), OPERATOR);
        YieldSeekerAgentWalletV3 implementation = new YieldSeekerAgentWalletV3(address(factory));
        factory.setAgentWalletImplementation(implementation);
        registry = new YieldSeekerAdapterRegistry(address(this), address(this));
        factory.setAdapterRegistry(AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);

        sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        sellPolicy.addSellableToken(address(reward));
        router = new MockLendingSwapRouter();
        swapAdapter = new YieldSeekerUniswapV3SwapAdapter(address(router), address(sellPolicy), oracle, SLIPPAGE_BPS);
        registry.registerAdapter(address(swapAdapter));
        registry.setTargetAdapter(address(router), address(swapAdapter));

        aavePool = new MockLendingAaveV3Pool();
        aWeth = new MockERC20("Aave WETH", "aWETH");
        variableDebtUsdc = new MockERC20("Variable Debt USDC", "vdUSDC");
        aavePool.setReserve(address(weth), address(aWeth), address(0));
        aavePool.setReserve(address(usdc), address(0), address(variableDebtUsdc));
        lendingAdapter = new YieldSeekerAaveV3LendingAdapter(oracle);
        registry.registerAdapter(address(lendingAdapter));
        bytes memory market = _aaveMarket();
        registry.setTargetAdapter(lendingAdapter.marketTarget(market), address(lendingAdapter));

        vm.prank(OPERATOR);
        wallet = factory.createAgentWallet(OWNER, 1, address(weth), AGENT_PROFILE);
    }

    function test_BaseToUsdcIsRejectedUntilTheWalletHasBorrowedUsdc() public {
        _supplyCollateral();
        usdc.mint(address(router), 5_000e6);
        router.setOutputAmount(2_000e6);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(AssetNotAllowed.selector)));
        _executeSwap(address(weth), address(usdc), 1e18, 1);

        _executeBorrow(1e6);
        _executeSwap(address(weth), address(usdc), 1e18, 1);
        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 2_001e6);
    }

    function test_BaseToBorrowedUsdcRejectsBelowOracleBoundAndAcceptsTheBoundary() public {
        _prepareBorrowedWallet();
        uint256 quote = oracle.quote(address(weth), address(usdc), 1e18);
        uint256 minimum = quote * (10_000 - SLIPPAGE_BPS) / 10_000;
        usdc.mint(address(router), minimum * 2);

        router.setOutputAmount(minimum - 1);
        vm.expectRevert(_adapterError(abi.encodeWithSelector(SwapBelowOraclePrice.selector, minimum - 1, minimum)));
        _executeSwap(address(weth), address(usdc), 1e18, 1);

        router.setOutputAmount(minimum);
        _executeSwap(address(weth), address(usdc), 1e18, 1);
        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1e6 + minimum);
    }

    function test_BaseToBorrowedUsdcCannotSpendVaultFeeReserve() public {
        _prepareBorrowedWallet();
        uint256 yieldAmount = 1e18;
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldEarned(yieldAmount);

        uint256 baseBalance = weth.balanceOf(address(wallet));
        uint256 reserved = feeTracker.getFeesOwed(address(wallet));
        assertEq(reserved, 0.1e18);
        uint256 unreservedAmount = baseBalance - reserved;
        uint256 routerOutput = oracle.quote(address(weth), address(usdc), baseBalance);
        usdc.mint(address(router), routerOutput * 2);
        router.setOutputAmount(routerOutput);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector)));
        _executeSwap(address(weth), address(usdc), baseBalance, 1);
        assertEq(weth.balanceOf(address(wallet)), baseBalance);

        _executeSwap(address(weth), address(usdc), unreservedAmount, 1);
        assertEq(weth.balanceOf(address(wallet)), reserved);
        assertEq(feeTracker.getFeesOwed(address(wallet)), reserved);
    }

    function test_BorrowedUsdcCannotBeSwappedBackToWeth() public {
        _prepareBorrowedWallet();

        vm.expectRevert(_adapterError(abi.encodeWithSelector(AssetNotAllowed.selector)));
        _executeSwap(address(usdc), address(weth), 1e6, 1);
    }

    function test_SellableRewardCanSwapToWethWithoutAnOraclePrice() public {
        uint256 rewardAmount = 7e18;
        uint256 wethOutput = 11e17;
        uint256 rewardFee = (rewardAmount * feeTracker.feeRateBps(VAULT_FEE, address(wallet))) / 10_000;
        reward.mint(address(wallet), rewardAmount);
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(reward), rewardAmount);
        weth.mint(address(router), wethOutput);
        router.setOutputAmount(wethOutput);

        _executeSwap(address(reward), address(weth), rewardAmount, 1);

        assertEq(reward.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), wethOutput);
        assertEq(feeTracker.getAgentYieldTokenFeesOwed(address(wallet), address(reward)), 0);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), (wethOutput * rewardFee) / rewardAmount);
    }

    function test_SellableRewardCannotBeSwappedToDebtToken() public {
        reward.mint(address(wallet), 1e18);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(AssetNotAllowed.selector)));
        _executeSwap(address(reward), address(usdc), 1e18, 1);
    }

    function test_NonSellableRewardCannotBeSold() public {
        unsupportedReward.mint(address(wallet), 1e18);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(SellTokenNotAllowed.selector, address(unsupportedReward))));
        _executeSwap(address(unsupportedReward), address(weth), 1e18, 1);
    }

    function test_LegacyTrackerWalletCanSellRewardsButNotSwapBaseAsset() public {
        YieldSeekerFeeTracker legacyTracker = new YieldSeekerFeeTracker(address(this), address(this), FEE_COLLECTOR, 10_000, 1_000);
        factory.setFeeTracker(legacyTracker);
        vm.prank(OPERATOR);
        YieldSeekerAgentWalletV3 legacyWallet = factory.createAgentWallet(OWNER, 2, address(weth), AGENT_PROFILE);
        uint256 rewardAmount = 1e18;
        uint256 wethOutput = 1e18;
        reward.mint(address(legacyWallet), rewardAmount);
        weth.mint(address(router), wethOutput);
        router.setOutputAmount(wethOutput);

        _executeSwapFromWallet(legacyWallet, address(reward), address(weth), rewardAmount, 1);

        assertEq(reward.balanceOf(address(legacyWallet)), 0);
        assertEq(weth.balanceOf(address(legacyWallet)), wethOutput);

        usdc.mint(address(router), 1e6);
        router.setOutputAmount(1e6);
        vm.expectRevert(_adapterError(abi.encodeWithSelector(AssetNotAllowed.selector)));
        _executeSwapFromWallet(legacyWallet, address(weth), address(usdc), wethOutput, 1);
    }

    function _prepareBorrowedWallet() private {
        _supplyCollateral();
        _executeBorrow(1e6);
    }

    function _supplyCollateral() private {
        weth.mint(address(wallet), 2e18);
        bytes memory market = _aaveMarket();
        _execute(address(lendingAdapter), lendingAdapter.marketTarget(market), abi.encodeWithSelector(lendingAdapter.supplyCollateral.selector, market, 1e18));
    }

    function _executeBorrow(uint256 amount) private {
        bytes memory market = _aaveMarket();
        _execute(address(lendingAdapter), lendingAdapter.marketTarget(market), abi.encodeWithSelector(lendingAdapter.borrow.selector, market, amount));
    }

    function _executeSwap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) private {
        _executeSwapFromWallet(wallet, sellToken, buyToken, sellAmount, minBuyAmount);
    }

    function _executeSwapFromWallet(YieldSeekerAgentWalletV3 targetWallet, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) private {
        address[] memory path = new address[](2);
        path[0] = sellToken;
        path[1] = buyToken;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        bytes memory data = abi.encodeWithSelector(swapAdapter.swap.selector, sellToken, buyToken, route, sellAmount, minBuyAmount);
        vm.prank(OPERATOR);
        targetWallet.executeViaAdapter(address(swapAdapter), address(router), data);
    }

    function _execute(address adapter, address target, bytes memory data) private {
        vm.prank(OPERATOR);
        wallet.executeViaAdapter(adapter, target, data);
    }

    function _aaveMarket() private view returns (bytes memory) {
        return abi.encode(address(aavePool), address(weth), address(usdc), uint8(0));
    }

    function _adapterError(bytes memory reason) private pure returns (bytes memory) {
        return abi.encodeWithSelector(AdapterExecutionFailed.selector, reason);
    }
}
