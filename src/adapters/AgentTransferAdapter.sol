// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {InvalidAsset, YieldSeekerAgentWalletV3} from "../AgentWalletV3.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {UnknownOperation} from "../agentwalletkit/AWKAdapter.sol";
import {AWKAgentWalletFactory} from "../agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidTransferTarget(address target);
error NotOwnersAgentWallet(address wallet);
error ReceiverIsExecuting(address wallet);

/**
 * @title YieldSeekerAgentTransferAdapter
 * @notice Move a token from this wallet to another agent wallet of the same owner
 * @dev Register this adapter as its own target. Both wallets must be the ones this wallet's factory deployed for the
 *      same owner (userWallets(owner, ownerAgentIndex) points back at them, so a look-alike contract cannot pass), and
 *      the receiver must still be owned by them.
 *      Both fee trackers must account for the token (so it can always be withdrawn there), and the transfer is
 *      reported first (FeeActions.TRANSFER_OUT) so fees owed are paid before the exact amount leaves.
 *      The receiver must not be mid-execution: an operator able to run code during another wallet's swap (e.g. from a
 *      token hook) could otherwise send tokens in and have them counted as the swap's output, faking the swap's
 *      oracle floor or a reward sale.
 */
contract YieldSeekerAgentTransferAdapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    event TransferredToAgentWallet(address indexed from, address indexed to, address indexed token, uint256 amount);

    function transfer(address token, address to, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.transfer.selector) revert UnknownOperation();
        if (target != SELF) revert InvalidTransferTarget(target);
        (address token, address to, uint256 amount) = abi.decode(data[4:], (address, address, uint256));
        if (amount == 0) revert AWKErrors.ZeroAmount();
        YieldSeekerAgentWalletV3 wallet = YieldSeekerAgentWalletV3(payable(address(this)));
        AWKAgentWalletFactory factory = AWKAgentWalletFactory(address(wallet.FACTORY()));
        address owner = wallet.owner();
        if (factory.userWallets(owner, wallet.ownerAgentIndex()) != address(this)) revert NotOwnersAgentWallet(address(this));
        if (factory.userWallets(owner, YieldSeekerAgentWalletV3(payable(to)).ownerAgentIndex()) != to || YieldSeekerAgentWalletV3(payable(to)).owner() != owner) revert NotOwnersAgentWallet(to);
        if (YieldSeekerAgentWalletV3(payable(to)).isExecuting()) revert ReceiverIsExecuting(to);
        if (!IAgentWallet(to).feeTracker().isAccountedToken(to, token) || !_feeTracker().isAccountedToken(address(this), token)) revert InvalidAsset();
        _reportAction(FeeActions.TRANSFER_OUT, abi.encode(FeeActions.TransferOut({token: token, to: to, amount: amount})));
        if (IERC20(token).balanceOf(address(this)) < amount) revert AWKErrors.InsufficientBalance();
        IERC20(token).safeTransfer(to, amount);
        emit TransferredToAgentWallet(address(this), to, token, amount);
        return abi.encode(amount);
    }
}
