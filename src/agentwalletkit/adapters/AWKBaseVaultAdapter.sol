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
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidPercentage(uint256 percentage);

/**
 * @title AWKBaseVaultAdapter
 * @notice Abstract base class for all vault adapters with pre/post hook support
 * @dev Defines the standard vault operations interface that all vault adapters must implement.
 *      Provides hook points for custom logic before/after operations.
 */
abstract contract AWKBaseVaultAdapter is AWKAdapter {
    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    /**
     * @notice Deposit assets into a vault (public interface, should not be called directly)
     * @param amount The amount of assets to deposit
     * @return shares The amount of vault shares received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _depositInternal()
     */
    function deposit(uint256 amount) external pure returns (uint256 shares) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Deposit a percentage of base asset balance into a vault (public interface, should not be called directly)
     * @param percentageBps The percentage in basis points (10000 = 100%)
     * @return shares The amount of vault shares received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _depositPercentageInternal()
     */
    function depositPercentage(uint256 percentageBps) external pure returns (uint256 shares) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Withdraw assets from a vault (public interface, should not be called directly)
     * @param shares The amount of vault shares to withdraw
     * @return assets The amount of assets received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _withdrawInternal()
     */
    function withdraw(uint256 shares) external pure returns (uint256 assets) {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Execution Logic ============

    /**
     * @notice Fetch the underlying asset of a vault
     * @param vault The vault address
     * @return asset The vault's underlying asset token
     * @dev Must be implemented by concrete vault adapters
     */
    function _getVaultAsset(address vault) internal view virtual returns (address);

    /**
     * @notice Execute generic vault operations
     * @dev Already running in wallet context via delegatecall from AgentWallet.
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.deposit.selector) {
            uint256 amount = abi.decode(data[4:], (uint256));
            uint256 shares = _depositInternal(target, amount);
            return abi.encode(shares);
        }
        if (selector == this.depositPercentage.selector) {
            uint256 percentageBps = abi.decode(data[4:], (uint256));
            address asset = _getVaultAsset(target);
            uint256 shares = _depositPercentageInternal(target, percentageBps, IERC20(asset));
            return abi.encode(shares);
        }
        if (selector == this.withdraw.selector) {
            uint256 shares = abi.decode(data[4:], (uint256));
            uint256 assets = _withdrawInternal(target, shares);
            return abi.encode(assets);
        }
        revert UnknownOperation();
    }

    // ============ Internal Implementations ============

    /**
     * @notice Internal deposit implementation
     * @param vault The vault address
     * @param amount The amount of assets to deposit
     * @return shares The amount of vault shares received
     * @dev Must be implemented by concrete vault adapters. Hooks are called automatically.
     */
    function _depositInternal(address vault, uint256 amount) internal virtual returns (uint256 shares);

    /**
     * @notice Internal deposit percentage implementation
     * @param vault The vault address
     * @param percentageBps The percentage in basis points (10000 = 100%)
     * @param baseAsset The base asset token
     * @return shares The amount of vault shares received
     * @dev Calculates amount based on balance and calls _depositInternal
     */
    function _depositPercentageInternal(address vault, uint256 percentageBps, IERC20 baseAsset) internal returns (uint256 shares) {
        if (percentageBps == 0 || percentageBps > 1e4) revert InvalidPercentage(percentageBps);
        uint256 balance = baseAsset.balanceOf(address(this));
        uint256 amount = (balance * percentageBps) / 1e4;
        return _depositInternal(vault, amount);
    }

    /**
     * @notice Internal withdraw implementation
     * @param vault The vault address
     * @param shares The amount of vault shares to withdraw
     * @return assets The amount of assets received
     * @dev Must be implemented by concrete vault adapters. Hooks are called automatically.
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual returns (uint256 assets);
}
