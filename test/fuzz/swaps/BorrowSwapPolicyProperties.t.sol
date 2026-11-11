// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {FeeActions} from "../../../src/fees/FeeActions.sol";
import {SwapAboveDebt, SwapBelowOraclePrice, YieldSeekerBorrowSwapPolicy} from "../../../src/swaps/BorrowSwapPolicy.sol";
import {SwapNotAllowed} from "../../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy} from "../../../src/swaps/VaultSwapPolicy.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockFeePriceFeed} from "../../mocks/MockFeePriceFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BorrowSwapPolicyProperties is IntegrationBase {
    function testFuzz_borrowSwapPolicyMatchesOracleAndDebtReferenceModel(uint8 tokenDecimalsSeed, uint256 tokenPriceAnswerSeed, uint256 soldAmountSeed, uint256 debtSeed, uint256 heldSeed, uint256 boughtSeed, uint16 slippageSeed) public {
        uint8 tokenDecimals = uint8(bound(tokenDecimalsSeed, 0, 24));
        uint256 tokenPriceAnswer = bound(tokenPriceAnswerSeed, 1e6, 1e12);
        uint256 soldAmount = bound(soldAmountSeed, 1e6, 1e15);
        uint256 maxTokenAmount = 1e9 * 10 ** tokenDecimals;
        uint256 debt = bound(debtSeed, 1, maxTokenAmount);
        uint256 held = bound(heldSeed, 0, maxTokenAmount * 2);
        uint256 bought = bound(boughtSeed, 0, maxTokenAmount * 2);
        uint256 slippageBps = bound(slippageSeed, 0, 9999);

        AgentWallet wallet = _createBorrowWallet(owner, 11);
        MockERC20WithDecimals debtToken = new MockERC20WithDecimals("Borrowed Token", "DEBT", tokenDecimals);
        MockFeePriceFeed debtPriceFeed = new MockFeePriceFeed(8, int256(tokenPriceAnswer), block.timestamp);
        priceOracle.setSource(address(debtToken), debtPriceFeed, 1 days);
        _recordBorrowedDebt(wallet, address(debtToken), debt);
        debtToken.mint(address(wallet), held);

        YieldSeekerBorrowSwapPolicy policy = new YieldSeekerBorrowSwapPolicy(swapSellPolicy, priceOracle, slippageBps);

        assertTrue(_borrowCallAllowed(policy, address(wallet), address(usdc), address(debtToken)));
        assertFalse(_borrowCallAllowed(policy, address(wallet), address(debtToken), address(usdc)));
        assertFalse(_borrowCallAllowed(policy, address(wallet), address(usdc), address(rewardToken)));
        assertTrue(_borrowCallAllowed(policy, address(wallet), address(rewardToken), address(usdc)));
        assertFalse(_borrowCallAllowed(policy, address(wallet), address(rewardToken), address(debtToken)));

        uint256 fromValue = Math.mulDiv(soldAmount, 1e18, 1e6);
        uint256 quote = Math.mulDiv(fromValue, 10 ** tokenDecimals, tokenPriceAnswer * 1e10);
        assertEq(priceOracle.quote(address(usdc), address(debtToken), soldAmount), quote, "oracle quote disagrees with token-unit model");
        uint256 minimum = Math.mulDiv(quote, 10_000 - slippageBps, 10_000, Math.Rounding.Ceil);
        uint256 debtLimit = Math.mulDiv(debt, 10_300, 10_000);
        bool referenceAccepts = bought >= minimum && held <= debtLimit;

        (bool success, bytes memory result) = address(policy).staticcall(abi.encodeCall(policy.checkSwapResult, (address(wallet), address(usdc), soldAmount, address(debtToken), bought)));
        assertEq(success, referenceAccepts, "borrow swap result differs from oracle/debt model");
        if (success) {
            assertEq(abi.decode(result, (bytes32)), FeeActions.SWAP);
        } else if (bought < minimum) {
            assertEq(_selector(result), SwapBelowOraclePrice.selector);
        } else {
            assertEq(_selector(result), SwapAboveDebt.selector);
        }

        bytes32 rewardAction = policy.checkSwapResult(address(wallet), address(rewardToken), soldAmount, address(usdc), bought);
        assertEq(rewardAction, FeeActions.REWARD_SALE, "reward sales stay reward sales regardless of debt or price");
    }

    function testFuzz_vaultSwapPolicyOnlySellsAllowedRewardsIntoBase(uint256 ignoredAmountSeed) public {
        uint256 ignoredAmount = bound(ignoredAmountSeed, 0, type(uint128).max);
        AgentWallet wallet = _createVaultWallet(owner, 12);
        MockERC20WithDecimals unlistedToken = new MockERC20WithDecimals("Unlisted", "NOPE", 18);
        assertFalse(_vaultCallAllowed(vaultSwapPolicy, address(wallet), address(unlistedToken), address(usdc)));
        swapSellPolicy.setAllowSellingAllTokens(true);

        vaultSwapPolicy.checkSwap(address(wallet), address(rewardToken), address(usdc));
        assertEq(vaultSwapPolicy.checkSwapResult(address(wallet), address(rewardToken), ignoredAmount, address(usdc), ignoredAmount), FeeActions.REWARD_SALE);

        assertFalse(_vaultCallAllowed(vaultSwapPolicy, address(wallet), address(usdc), address(rewardToken)));
        assertFalse(_vaultCallAllowed(vaultSwapPolicy, address(wallet), address(rewardToken), address(weth)));
        assertFalse(_vaultCallAllowed(vaultSwapPolicy, address(wallet), address(erc4626Vault), address(usdc)));
    }

    function testPowerUserSellsCollateralAndRepaysUntilTheBorrowIsClosed() public {
        AgentWallet wallet = _createBorrowWallet(owner, 13);
        uint256 initialDebt = 1e18;
        _borrowWeth(wallet, 3_000e6, initialDebt);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        assertEq(weth.balanceOf(address(wallet)), 0);

        uint256[3] memory ethPrices = [uint256(1_500e8), uint256(2_400e8), uint256(1_800e8)];
        for (uint256 i = 0; i < ethPrices.length; i++) {
            uint256 now_ = block.timestamp;
            wethPriceFeed.setPrice(int256(ethPrices[i]), now_);

            uint256 debtBefore = borrowFeeModule.tokenDebt(address(wallet), address(weth));
            uint256 buyAmount = i == ethPrices.length - 1 ? debtBefore : debtBefore / (i == 0 ? 4 : 3);
            uint256 sellAmount = priceOracle.quote(address(weth), address(usdc), buyAmount);
            assertGt(sellAmount, 0);
            assertEq(usdc.balanceOf(address(wallet)), 0, "previous swap left collateral in the wallet");
            _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, sellAmount)));
            assertEq(usdc.balanceOf(address(wallet)), sellAmount, "swap input did not come from withdrawn collateral");
            uniswapV3Router.setBuyAmount(buyAmount);

            AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
            _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, sellAmount, uint256(1), block.timestamp)));

            assertEq(weth.balanceOf(address(wallet)), buyAmount);
            assertLe(weth.balanceOf(address(wallet)), Math.mulDiv(debtBefore, 10_300, 10_000), "swap held more than debt plus 3% buffer");

            uint256 repayAmount = i == ethPrices.length - 1 ? type(uint256).max : buyAmount;
            _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, repayAmount)));
            assertEq(weth.balanceOf(address(wallet)), 0);
        }

        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0, "full close left debt in the borrow fee ledger");
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0, "full close left protocol debt");
    }

    function _recordBorrowedDebt(AgentWallet wallet, address token, uint256 debt) private {
        FeeActions.DebtChange memory change = FeeActions.DebtChange({market: address(0xB0A0), debtToken: token, debtBefore: 0, borrowed: debt, repaid: 0, debtPriceInBaseAsset: 0});
        vm.prank(address(wallet));
        borrowFeeTracker.reportAction(FeeActions.DEBT_CHANGE, abi.encode(change));
        assertEq(borrowFeeModule.tokenDebt(address(wallet), token), debt);
        assertTrue(borrowFeeModule.isAccountedToken(address(wallet), token));
    }

    function _borrowWeth(AgentWallet wallet, uint256 collateralAmount, uint256 borrowedAmount) private {
        _fundWallet(wallet, address(usdc), collateralAmount);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowedAmount)));
    }

    function _borrowCallAllowed(YieldSeekerBorrowSwapPolicy policy, address wallet, address sellToken, address buyToken) private view returns (bool allowed) {
        (allowed,) = address(policy).staticcall(abi.encodeCall(policy.checkSwap, (wallet, sellToken, buyToken)));
    }

    function _vaultCallAllowed(YieldSeekerVaultSwapPolicy policy, address wallet, address sellToken, address buyToken) private view returns (bool allowed) {
        (allowed,) = address(policy).staticcall(abi.encodeCall(policy.checkSwap, (wallet, sellToken, buyToken)));
    }

    function _selector(bytes memory revertData) private pure returns (bytes4 selector) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(revertData, 0x20))
        }
    }

    function _uniswapRoute(address from, address to) private pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
    }
}
