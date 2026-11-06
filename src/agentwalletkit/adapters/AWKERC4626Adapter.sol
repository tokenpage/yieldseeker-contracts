// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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
 * @dev Handles deposits and withdrawals for standard ERC4626 vaults.
 */
abstract contract AWKERC4626Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Fetch asset from vault
     */
    function _getVaultAsset(address vault) internal view override returns (address) {
        return IERC4626(vault).asset();
    }

    function _deposit(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = IERC4626(vault).asset();
        uint256 baseAssetBalanceBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit({assets: amount, receiver: address(this)});
        require(shares > 0, "AWKERC4626Adapter: zero shares minted");
        assetsDeposited = baseAssetBalanceBefore - IERC20(asset).balanceOf(address(this));
    }

    /// @dev Measured as the change in the wallet's asset balance, not redeem's return value. A redeem that pays nothing
    ///      reverts: some vaults (e.g. yo) turn a redemption above their free balance into a queued request that takes
    ///      the shares and pays later, which would otherwise be reported as a completed withdrawal of zero.
    function _withdraw(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        IERC20 asset = IERC20(IERC4626(vault).asset());
        uint256 balanceBefore = asset.balanceOf(address(this));
        IERC4626(vault).redeem({shares: shares, receiver: address(this), owner: address(this)});
        assets = asset.balanceOf(address(this)) - balanceBefore;
        require(assets > 0, "AWKERC4626Adapter: nothing received");
    }
}
