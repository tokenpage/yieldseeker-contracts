// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKAerodromeCLSwapAdapter} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerVaultSwapPolicy} from "../../src/swaps/VaultSwapPolicy.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IV3PeripheryRouter {
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function refundETH() external payable;
}

/// @dev SwapRouter02 and the Slipstream router pay a WETH input from their own ETH when they hold enough. Anyone can
///      park ETH there, so the adapters sweep it to the wallet first and the wallet still pays exactly its WETH.
contract RouterEthSweepForkTest is ForkBase {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant AERODROME_CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    uint256 internal constant SELL_AMOUNT = 0.1 ether;

    YieldSeekerUniswapV3SwapAdapter internal uniswapAdapter;
    YieldSeekerAerodromeCLSwapAdapter internal clAdapter;
    AgentWallet internal wallet;
    address internal parker = makeAddr("parker");

    function setUp() public override {
        super.setUp();
        vm.deal(parker, 10 ether);
        YieldSeekerSwapSellPolicy sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        sellPolicy.addSellableToken(WETH);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, new YieldSeekerVaultSwapPolicy(sellPolicy));
        uniswapAdapter = new YieldSeekerUniswapV3SwapAdapter(UNISWAP_V3_ROUTER);
        clAdapter = new YieldSeekerAerodromeCLSwapAdapter(AERODROME_CL_ROUTER);
        _registerAdapter(address(uniswapAdapter), UNISWAP_V3_ROUTER);
        _registerAdapter(address(clAdapter), AERODROME_CL_ROUTER);
        wallet = _createVaultWallet(USDC, 0);
        deal(WETH, address(wallet), SELL_AMOUNT);
        vm.startPrank(makeAddr("sweeper"));
        IV3PeripheryRouter(UNISWAP_V3_ROUTER).refundETH();
        IV3PeripheryRouter(AERODROME_CL_ROUTER).refundETH();
        vm.stopPrank();
    }

    function test_WethSaleThroughSwapRouter02WithParkedEthIsPaidByTheWallet() public {
        _parkEth(UNISWAP_V3_ROUTER);
        uint256 ethBefore = address(wallet).balance;

        _execute(wallet, address(uniswapAdapter), UNISWAP_V3_ROUTER, _uniswapSwap());

        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0);
        assertGt(IERC20(USDC).balanceOf(address(wallet)), 0);
        assertEq(UNISWAP_V3_ROUTER.balance, 0);
        assertEq(address(wallet).balance - ethBefore, SELL_AMOUNT);
    }

    function test_WethSaleThroughSlipstreamWithParkedEthIsPaidByTheWallet() public {
        _parkEth(AERODROME_CL_ROUTER);
        uint256 ethBefore = address(wallet).balance;

        _execute(wallet, address(clAdapter), AERODROME_CL_ROUTER, _clSwap());

        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0);
        assertGt(IERC20(USDC).balanceOf(address(wallet)), 0);
        assertEq(AERODROME_CL_ROUTER.balance, 0);
        assertEq(address(wallet).balance - ethBefore, SELL_AMOUNT);
    }

    function _parkEth(address router) internal {
        vm.prank(parker);
        IV3PeripheryRouter(router).multicall{value: SELL_AMOUNT}(new bytes[](0));
        assertEq(router.balance, SELL_AMOUNT);
    }

    function _uniswapSwap() internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        return abi.encodeCall(uniswapAdapter.swap, (WETH, USDC, AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees}), SELL_AMOUNT, uint256(1), block.timestamp));
    }

    function _clSwap() internal view returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        int24[] memory tickSpacings = new int24[](1);
        tickSpacings[0] = 100;
        return abi.encodeCall(clAdapter.swap, (WETH, USDC, AWKAerodromeCLSwapAdapter.SwapRoute({path: path, tickSpacings: tickSpacings}), SELL_AMOUNT, uint256(1), block.timestamp));
    }
}
