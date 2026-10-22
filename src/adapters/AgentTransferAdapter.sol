// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {InvalidAsset} from "../AgentWalletV1.sol";
import {YieldSeekerAgentWalletV3} from "../AgentWalletV3.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {YieldSeekerWalletLinkRegistry} from "../WalletLinkRegistry.sol";
import {UnknownOperation} from "../agentwalletkit/AWKAdapter.sol";
import {AWKAgentWalletFactory} from "../agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidTransferTarget(address target);
error NotLinkedWallet(address wallet);

/**
 * @title YieldSeekerAgentTransferAdapter
 * @notice Move a token from this wallet to another agent wallet of the same owner that the owner linked
 * @dev Register LINK_REGISTRY as this adapter's target. The receiving wallet must be recorded by this wallet's
 *      factory (so it runs the factory's code and cannot be a look-alike contract), have the same owner, and be
 *      linked by that owner. The receiver's fee tracker must allow the token (so it can always be withdrawn there),
 *      and the sender may only move what its owner could withdraw (so fees owed stay behind).
 */
contract YieldSeekerAgentTransferAdapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    YieldSeekerWalletLinkRegistry public immutable LINK_REGISTRY;

    event TransferredToLinkedWallet(address indexed from, address indexed to, address indexed token, uint256 amount);

    constructor(YieldSeekerWalletLinkRegistry linkRegistry) {
        if (address(linkRegistry) == address(0)) revert AWKErrors.ZeroAddress();
        LINK_REGISTRY = linkRegistry;
    }

    function transfer(address token, address to, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.transfer.selector) revert UnknownOperation();
        if (target != address(LINK_REGISTRY)) revert InvalidTransferTarget(target);
        (address token, address to, uint256 amount) = abi.decode(data[4:], (address, address, uint256));
        if (amount == 0) revert AWKErrors.ZeroAmount();
        YieldSeekerAgentWalletV3 wallet = YieldSeekerAgentWalletV3(payable(address(this)));
        AWKAgentWalletFactory factory = AWKAgentWalletFactory(address(wallet.FACTORY()));
        if (factory.walletProfile(address(this)) == bytes32(0) || factory.walletProfile(to) == bytes32(0)) revert NotLinkedWallet(to);
        if (YieldSeekerAgentWalletV3(payable(to)).owner() != wallet.owner()) revert NotLinkedWallet(to);
        if (!LINK_REGISTRY.isLinked(address(this), to)) revert NotLinkedWallet(to);
        (bool receiverAllows,) = IAgentWallet(to).feeTracker().withdrawReserve(to, token);
        (bool senderAllows, uint256 feesOwed) = _feeTracker().withdrawReserve(address(this), token);
        if (!receiverAllows || !senderAllows) revert InvalidAsset();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < feesOwed || amount > balance - feesOwed) revert AWKErrors.InsufficientBalance();
        IERC20(token).safeTransfer(to, amount);
        emit TransferredToLinkedWallet(address(this), to, token, amount);
        return abi.encode(amount);
    }
}
