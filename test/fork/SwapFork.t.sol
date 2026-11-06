// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter} from "../../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKAerodromeCLSwapAdapter} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter} from "../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerVaultSwapPolicy} from "../../src/swaps/VaultSwapPolicy.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SwapForkTest is ForkBase {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant AERODROME_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address internal constant AERODROME_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address internal constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address internal constant AERODROME_CL_3_ROUTER = 0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 internal constant SELL_AMOUNT = 0.01 ether;
    uint256 internal constant MAX_PRICE_IMPACT_BPS = 300;

    YieldSeekerPriceOracle internal oracle;
    YieldSeekerUniswapV3SwapAdapter internal uniswapAdapter;
    YieldSeekerAerodromeV2SwapAdapter internal aerodromeV2Adapter;
    YieldSeekerAerodromeCLSwapAdapter internal aerodromeCLAdapter;
    YieldSeekerAerodromeCLSwapAdapter internal aerodromeCL3Adapter;
    AgentWallet internal wallet;

    function setUp() public override {
        super.setUp();
        oracle = new YieldSeekerPriceOracle(address(this), address(this), IPriceFeed(SEQUENCER_UPTIME_FEED));
        oracle.setSource(WETH, IPriceFeed(ETH_USD_FEED), 1 hours);
        oracle.setSource(USDC, IPriceFeed(USDC_USD_FEED), 25 hours);
        YieldSeekerSwapSellPolicy sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        sellPolicy.addSellableToken(WETH);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, new YieldSeekerVaultSwapPolicy(sellPolicy));
        uniswapAdapter = new YieldSeekerUniswapV3SwapAdapter(UNISWAP_V3_ROUTER);
        aerodromeV2Adapter = new YieldSeekerAerodromeV2SwapAdapter(AERODROME_V2_ROUTER, AERODROME_V2_FACTORY);
        aerodromeCLAdapter = new YieldSeekerAerodromeCLSwapAdapter(AERODROME_CL_ROUTER);
        aerodromeCL3Adapter = new YieldSeekerAerodromeCLSwapAdapter(AERODROME_CL_3_ROUTER);
        _registerAdapter(address(uniswapAdapter), UNISWAP_V3_ROUTER);
        _registerAdapter(address(aerodromeV2Adapter), AERODROME_V2_ROUTER);
        _registerAdapter(address(aerodromeCLAdapter), AERODROME_CL_ROUTER);
        _registerAdapter(address(aerodromeCL3Adapter), AERODROME_CL_3_ROUTER);
        wallet = _createVaultWallet(USDC, 0);
        deal(WETH, address(wallet), SELL_AMOUNT);
    }

    function test_UniswapV3SingleAndTwoHopRewardSales() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        _assertRewardSale(address(uniswapAdapter), UNISWAP_V3_ROUTER, abi.encodeCall(uniswapAdapter.swap, (WETH, USDC, AWKUniswapV3SwapAdapter.SwapRoute({path: _path(false), fees: fees}), SELL_AMOUNT, 1)));

        fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        _assertRewardSale(address(uniswapAdapter), UNISWAP_V3_ROUTER, abi.encodeCall(uniswapAdapter.swap, (WETH, USDC, AWKUniswapV3SwapAdapter.SwapRoute({path: _path(true), fees: fees}), SELL_AMOUNT, 1)));
    }

    function test_AerodromeV2SingleAndTwoHopRewardSales() public {
        bool[] memory stables = new bool[](1);
        _assertRewardSale(address(aerodromeV2Adapter), AERODROME_V2_ROUTER, abi.encodeCall(aerodromeV2Adapter.swap, (WETH, USDC, AWKAerodromeV2SwapAdapter.SwapRoute({path: _path(false), stables: stables}), SELL_AMOUNT, 1)));

        stables = new bool[](2);
        _assertRewardSale(address(aerodromeV2Adapter), AERODROME_V2_ROUTER, abi.encodeCall(aerodromeV2Adapter.swap, (WETH, USDC, AWKAerodromeV2SwapAdapter.SwapRoute({path: _path(true), stables: stables}), SELL_AMOUNT, 1)));
    }

    function test_AerodromeCLSingleAndTwoHopRewardSales() public {
        int24[] memory tickSpacings = new int24[](1);
        tickSpacings[0] = 100;
        _assertRewardSale(address(aerodromeCLAdapter), AERODROME_CL_ROUTER, abi.encodeCall(aerodromeCLAdapter.swap, (WETH, USDC, AWKAerodromeCLSwapAdapter.SwapRoute({path: _path(false), tickSpacings: tickSpacings}), SELL_AMOUNT, 1)));

        tickSpacings = new int24[](2);
        tickSpacings[0] = 100;
        tickSpacings[1] = 100;
        _assertRewardSale(address(aerodromeCLAdapter), AERODROME_CL_ROUTER, abi.encodeCall(aerodromeCLAdapter.swap, (WETH, USDC, AWKAerodromeCLSwapAdapter.SwapRoute({path: _path(true), tickSpacings: tickSpacings}), SELL_AMOUNT, 1)));
    }

    function test_AerodromeCLThirdRouterSpacing10RewardSale() public {
        int24[] memory tickSpacings = new int24[](1);
        tickSpacings[0] = 10;
        uint256 walletUsdcBefore = IERC20(USDC).balanceOf(address(wallet));
        uint256 collectorUsdcBefore = IERC20(USDC).balanceOf(feeCollector);
        deal(WETH, address(wallet), SELL_AMOUNT);

        uint256 bought = abi.decode(
            abi.decode(
                _execute(
                    wallet, address(aerodromeCL3Adapter), AERODROME_CL_3_ROUTER, abi.encodeCall(aerodromeCL3Adapter.swap, (WETH, USDC, AWKAerodromeCLSwapAdapter.SwapRoute({path: _path(false), tickSpacings: tickSpacings}), SELL_AMOUNT, 1))
                ),
                (bytes)
            ),
            (uint256)
        );
        uint256 fee = Math.mulDiv(bought, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);

        assertGt(bought, 1, "the router swapped through the real spacing-10 pool");
        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0);
        assertEq(IERC20(USDC).balanceOf(address(wallet)) - walletUsdcBefore, bought - fee);
        assertEq(IERC20(USDC).balanceOf(feeCollector) - collectorUsdcBefore, fee);
        assertEq(IERC20(WETH).allowance(address(wallet), AERODROME_CL_3_ROUTER), 0);
    }

    function _assertRewardSale(address adapter, address router, bytes memory data) internal {
        uint256 minimum = oracle.quote(WETH, USDC, SELL_AMOUNT) * (10_000 - MAX_PRICE_IMPACT_BPS) / 10_000;
        uint256 walletUsdcBefore = IERC20(USDC).balanceOf(address(wallet));
        uint256 collectorUsdcBefore = IERC20(USDC).balanceOf(feeCollector);
        deal(WETH, address(wallet), SELL_AMOUNT);

        uint256 bought = abi.decode(abi.decode(_execute(wallet, adapter, router, data), (bytes)), (uint256));

        uint256 fee = Math.mulDiv(bought, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        assertGe(bought, minimum, "the route ran through real pools at the market price");
        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0, "the whole sell amount was sold");
        assertEq(IERC20(USDC).balanceOf(address(wallet)) - walletUsdcBefore, bought - fee, "the wallet received the output net of the yield fee");
        assertEq(IERC20(USDC).balanceOf(feeCollector) - collectorUsdcBefore, fee, "the yield fee was paid");
        assertEq(IERC20(WETH).allowance(address(wallet), router), 0, "no router approval is left");
    }

    function _path(bool viaCbBtc) internal pure returns (address[] memory path) {
        path = new address[](viaCbBtc ? 3 : 2);
        path[0] = WETH;
        if (viaCbBtc) path[1] = CBBTC;
        path[path.length - 1] = USDC;
    }
}
