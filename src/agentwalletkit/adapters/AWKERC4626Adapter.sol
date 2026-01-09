// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../AWKErrors.sol";
import {AWKBaseVaultAdapter} from "./AWKBaseVaultAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IERC4626
 * @notice Minimal ERC4626 interface
 */
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/**
 * @title AWKERC4626Adapter
 * @notice Generic adapter for interacting with ERC4626 tokenized vaults
 * @dev Handles deposits and withdrawals for standard ERC4626 vaults with pre/post hooks.
 *      Subclasses can override hooks to add custom logic (e.g., fee tracking).
 */
abstract contract AWKERC4626Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Override execute to handle vault operations
     * @dev Already running in wallet context via delegatecall from AgentWallet.
     *      Subclasses must implement this to provide baseAsset for depositPercentage.
     */
    function execute(address target, bytes calldata data) external payable virtual override returns (bytes memory);

    /**
     * @notice Internal deposit implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _depositInternal(address vault, uint256 amount) internal virtual override returns (uint256 shares) {
        if (amount == 0) revert AWKErrors.ZeroAmount();
        address asset = IERC4626(vault).asset();
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit({assets: amount, receiver: address(this)});
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Internal withdraw implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        if (shares == 0) revert AWKErrors.ZeroAmount();
        assets = IERC4626(vault).redeem({shares: shares, receiver: address(this), owner: address(this)});
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
