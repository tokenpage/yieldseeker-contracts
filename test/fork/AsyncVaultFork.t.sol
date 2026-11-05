// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {AdapterExecutionFailed} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice yoUSD turns a redemption above its free balance into a queued request that takes the shares and pays later;
///         the adapter must not report that as a completed withdrawal
contract AsyncVaultForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant YO_USD = 0x0000000f2eB9f69274678c76222B35eEc7588a65;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_QueuedYoRedemptionRevertsAndAFundedOneWithdraws() public {
        AgentWallet wallet = _createVaultWallet(USDC, 0);
        YieldSeekerERC4626Adapter adapter = new YieldSeekerERC4626Adapter();
        _registerAdapter(address(adapter), YO_USD);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);
        _execute(wallet, address(adapter), YO_USD, abi.encodeCall(adapter.deposit, (DEPOSIT_AMOUNT)));
        uint256 shares = IERC20(YO_USD).balanceOf(address(wallet));
        assertGt(shares, 0);

        uint256 freeBalance = IERC20(USDC).balanceOf(YO_USD);
        deal(USDC, YO_USD, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, abi.encodeWithSignature("Error(string)", "AWKERC4626Adapter: nothing received")));
        wallet.executeViaAdapter(address(adapter), YO_USD, abi.encodeCall(adapter.withdraw, (shares)));
        assertEq(IERC20(YO_USD).balanceOf(address(wallet)), shares);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), YO_USD), DEPOSIT_AMOUNT);

        deal(USDC, YO_USD, freeBalance);
        _execute(wallet, address(adapter), YO_USD, abi.encodeCall(adapter.withdraw, (shares)));
        assertEq(IERC20(YO_USD).balanceOf(address(wallet)), 0);
        assertGt(IERC20(USDC).balanceOf(address(wallet)), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), YO_USD), 0);
    }
}
