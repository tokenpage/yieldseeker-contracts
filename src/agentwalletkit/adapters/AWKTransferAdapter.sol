// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKAgentWalletFactory} from "../AWKAgentWalletFactory.sol";
import {AWKAgentWalletV2} from "../AWKAgentWalletV2.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {AWKWalletLinkRegistry} from "../AWKWalletLinkRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidTransferTarget(address target);
error NotLinkedWallet(address wallet);

/**
 * @title AWKTransferAdapter
 * @notice Move a token from this wallet to another wallet of the same owner that the owner linked
 * @dev Register LINK_REGISTRY as this adapter's target. The receiving wallet must be recorded by this wallet's
 *      factory (so it runs the factory's code and cannot be a look-alike contract), have the same owner, and be
 *      linked by that owner in LINK_REGISTRY.
 */
contract AWKTransferAdapter is AWKAdapter {
    using SafeERC20 for IERC20;

    AWKWalletLinkRegistry public immutable LINK_REGISTRY;

    event TransferredToLinkedWallet(address indexed from, address indexed to, address indexed token, uint256 amount);

    constructor(AWKWalletLinkRegistry linkRegistry) {
        if (address(linkRegistry) == address(0)) revert AWKErrors.ZeroAddress();
        LINK_REGISTRY = linkRegistry;
    }

    function transfer(address token, address to, uint256 amount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.transfer.selector) revert UnknownOperation();
        if (target != address(LINK_REGISTRY)) revert InvalidTransferTarget(target);
        (address token, address to, uint256 amount) = abi.decode(data[4:], (address, address, uint256));
        if (amount == 0) revert AWKErrors.ZeroAmount();
        AWKAgentWalletV2 wallet = AWKAgentWalletV2(payable(address(this)));
        AWKAgentWalletFactory factory = AWKAgentWalletFactory(address(wallet.FACTORY()));
        if (factory.walletProfile(address(this)) == bytes32(0) || factory.walletProfile(to) == bytes32(0)) revert NotLinkedWallet(to);
        if (AWKAgentWalletV2(payable(to)).owner() != wallet.owner()) revert NotLinkedWallet(to);
        if (!LINK_REGISTRY.isLinked(address(this), to)) revert NotLinkedWallet(to);
        _beforeTransfer(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
        emit TransferredToLinkedWallet(address(this), to, token, amount);
        return abi.encode(amount);
    }

    /// @dev Subclasses restrict which tokens and how much may move
    function _beforeTransfer(address token, address to, uint256 amount) internal view virtual {}
}
