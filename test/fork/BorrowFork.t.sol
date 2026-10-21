// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter} from "../../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerTransferAdapter} from "../../src/adapters/TransferAdapter.sol";
import {YieldSeekerUniswapV3PairSwapAdapter} from "../../src/adapters/UniswapV3PairSwapAdapter.sol";
import {AWKWalletLinkRegistry} from "../../src/agentwalletkit/AWKWalletLinkRegistry.sol";
import {IMorphoBlue} from "../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/// @notice End-to-end borrow flows against live Base protocols. Run with:
///   forge test --fork-url http://127.0.0.1:8545 --match-path test/fork/BorrowFork.t.sol -vv
contract BorrowForkTest is Test {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    bytes32 internal constant MORPHO_WETH_USDC_MARKET_ID = 0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;
    bytes32 internal constant BORROW_PROFILE = keccak256("borrow");
    bytes32 internal constant VAULT_PROFILE = keccak256("vault");

    address internal operator = makeAddr("operator");
    address internal owner = makeAddr("owner");
    address internal feeCollector = makeAddr("feeCollector");

    AgentWalletFactory internal factory;
    AdapterRegistry internal borrowRegistry;
    YieldSeekerBorrowFeeModule internal borrowFeeModule;
    YieldSeekerPriceOracle internal oracle;
    AWKWalletLinkRegistry internal linkRegistry;
    YieldSeekerAaveV3LendingAdapter internal aaveAdapter;
    YieldSeekerMorphoBlueLendingAdapter internal morphoAdapter;
    YieldSeekerUniswapV3PairSwapAdapter internal swapAdapter;
    YieldSeekerTransferAdapter internal transferAdapter;
    AgentWallet internal wallet;

    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
        vm.deal(operator, 1 ether);
        vm.deal(owner, 1 ether);
        oracle = new YieldSeekerPriceOracle(address(this), address(this), IPriceFeed(SEQUENCER_UPTIME_FEED));
        oracle.setSource(WETH, IPriceFeed(ETH_USD_FEED), 1 hours);
        oracle.setSource(USDC, IPriceFeed(USDC_USD_FEED), 25 hours);
        borrowFeeModule = new YieldSeekerBorrowFeeModule(address(this), address(this), feeCollector, 200, 50);
        FeeTracker vaultFeeModule = new FeeTracker(address(this), address(this), feeCollector, 5000, 1000);
        borrowRegistry = new AdapterRegistry(address(this), address(this));
        AdapterRegistry vaultRegistry = new AdapterRegistry(address(this), address(this));
        factory = new AgentWalletFactory(address(this), operator);
        factory.setAgentWalletImplementation(new AgentWallet(address(factory)));
        factory.setAdapterRegistry(BORROW_PROFILE, borrowRegistry);
        factory.setFeeTracker(BORROW_PROFILE, FeeTracker(address(borrowFeeModule)));
        factory.setAdapterRegistry(VAULT_PROFILE, vaultRegistry);
        factory.setFeeTracker(VAULT_PROFILE, FeeTracker(address(vaultFeeModule)));
        aaveAdapter = new YieldSeekerAaveV3LendingAdapter(oracle);
        morphoAdapter = new YieldSeekerMorphoBlueLendingAdapter(oracle);
        YieldSeekerSwapSellPolicy rewardSellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        swapAdapter = new YieldSeekerUniswapV3PairSwapAdapter(UNISWAP_V3_ROUTER, address(rewardSellPolicy), oracle, 100);
        linkRegistry = new AWKWalletLinkRegistry();
        transferAdapter = new YieldSeekerTransferAdapter(linkRegistry);
        _register(borrowRegistry, address(aaveAdapter), aaveAdapter.marketTarget(_aaveMarket()));
        _register(borrowRegistry, address(morphoAdapter), morphoAdapter.marketTarget(_morphoMarket()));
        _register(borrowRegistry, address(swapAdapter), UNISWAP_V3_ROUTER);
        _register(borrowRegistry, address(transferAdapter), address(linkRegistry));
        _register(vaultRegistry, address(transferAdapter), address(linkRegistry));
        vm.prank(operator);
        wallet = factory.createAgentWallet(owner, 0, WETH, BORROW_PROFILE);
        deal(WETH, address(wallet), 1 ether);
    }

    function _register(AdapterRegistry registry, address adapter, address target) internal {
        if (!registry.isRegisteredAdapter(adapter)) registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
    }

    function _execute(address adapter, address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(operator);
        return abi.decode(wallet.executeViaAdapter(adapter, target, data), (bytes));
    }

    function _aaveMarket() internal pure returns (bytes memory) {
        return abi.encode(AAVE_POOL, WETH, USDC, uint8(0));
    }

    function _morphoParams() internal pure returns (IMorphoBlue.MarketParams memory) {
        return IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: WETH, oracle: 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4, irm: 0x46415998764C29aB2a25CbeA6254146D50D22687, lltv: 860000000000000000});
    }

    function _morphoMarket() internal pure returns (bytes memory) {
        return abi.encode(MORPHO, _morphoParams());
    }

    function _runBorrowCycle(address adapter, bytes memory market) internal {
        address target = aaveAdapter.marketTarget(market);
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 1 ether));
        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0, "collateral supplied");
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 1_000e6));
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 1_000e6, "borrowed cash in wallet");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.roll(block.number + 1);
        deal(USDC, address(wallet), 1_200e6);

        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.repay.selector, market, type(uint256).max));
        assertEq(IERC20(USDC).balanceOf(feeCollector), 5e6, "0.5% of principal for a year paid on repay");
        (uint256 principal,,,) = borrowFeeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 0, "principal cleared");
        assertEq(borrowFeeModule.feesOwed(address(wallet), USDC), 0, "nothing owed");

        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.withdrawCollateral.selector, market, type(uint256).max));
        assertGe(IERC20(WETH).balanceOf(address(wallet)), 1 ether - 1, "collateral back in wallet");

        uint256 usdcLeft = IERC20(USDC).balanceOf(address(wallet));
        vm.startPrank(owner);
        wallet.withdrawAllAssetToUser(owner, WETH);
        wallet.withdrawAllAssetToUser(owner, USDC);
        vm.stopPrank();
        assertGe(IERC20(WETH).balanceOf(owner), 1 ether - 1, "owner exits with collateral");
        assertEq(IERC20(USDC).balanceOf(owner), usdcLeft, "owner exits with leftover cash");
    }

    function test_AaveV3_BorrowRepayWithdrawChargesBorrowFee() public {
        _runBorrowCycle(address(aaveAdapter), _aaveMarket());
    }

    function test_MorphoBlue_BorrowRepayWithdrawChargesBorrowFee() public {
        assertEq(keccak256(abi.encode(_morphoParams())), MORPHO_WETH_USDC_MARKET_ID, "market params match the live market id");
        _runBorrowCycle(address(morphoAdapter), _morphoMarket());
    }

    function test_PairSwap_SellsCollateralForBorrowedTokenWithinOracleBound() public {
        bytes memory market = _aaveMarket();
        address target = aaveAdapter.marketTarget(market);
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 0.5 ether));
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 100e6));
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        bytes memory result = _execute(address(swapAdapter), UNISWAP_V3_ROUTER, abi.encodeWithSelector(swapAdapter.swap.selector, WETH, USDC, route, 0.1 ether, 1));
        uint256 bought = abi.decode(result, (uint256));
        assertGe(bought, (oracle.quote(WETH, USDC, 0.1 ether) * 99) / 100, "swap output within the oracle bound");
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 100e6 + bought, "borrowed token received");
    }

    function test_Transfer_MovesBorrowedCashToLinkedVaultAgent() public {
        vm.prank(operator);
        AgentWallet vaultWallet = factory.createAgentWallet(owner, 1, USDC, VAULT_PROFILE);
        bytes memory market = _aaveMarket();
        address target = aaveAdapter.marketTarget(market);
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 1 ether));
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 500e6));
        vm.prank(owner);
        linkRegistry.setLinked(address(wallet), address(vaultWallet), true);
        _execute(address(transferAdapter), address(linkRegistry), abi.encodeWithSelector(transferAdapter.transfer.selector, USDC, address(vaultWallet), 500e6));
        assertEq(IERC20(USDC).balanceOf(address(vaultWallet)), 500e6, "vault agent received the borrowed cash");
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 0, "borrow agent sent it all");
    }
}
