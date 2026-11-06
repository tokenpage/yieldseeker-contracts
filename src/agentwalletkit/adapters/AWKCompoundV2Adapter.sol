// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKBaseVaultAdapter} from "./AWKBaseVaultAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ICToken
 * @notice Minimal Compound V2 cToken/mToken interface (used by Moonwell and other Compound V2 forks)
 */
interface ICToken {
    function underlying() external view returns (address);
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

/**
 * @title AWKCompoundV2Adapter
 * @notice Generic adapter for interacting with Compound V2 style lending protocols (Moonwell, etc.)
 * @dev Handles deposits and withdrawals for Compound V2 style protocols using cTokens/mTokens.
 *      The target address is the cToken/mToken address.
 *      These protocols use exchange rate based tokens where cToken balance * exchangeRate = underlying.
 */
abstract contract AWKCompoundV2Adapter is AWKBaseVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Fetch underlying asset from cToken/mToken
     */
    function _getVaultAsset(address vault) internal view override returns (address) {
        return ICToken(vault).underlying();
    }

    /// @dev The amount is the underlying asset amount; shares are the cTokens received
    function _deposit(address vault, uint256 amount) internal virtual override returns (uint256 shares, uint256 assetsDeposited) {
        address asset = ICToken(vault).underlying();
        uint256 baseAssetBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 balanceBefore = ICToken(vault).balanceOf(address(this));
        IERC20(asset).forceApprove(vault, amount);
        uint256 mintResult = ICToken(vault).mint(amount);
        require(mintResult == 0, "AWKCompoundV2Adapter: mint failed");
        uint256 balanceAfter = ICToken(vault).balanceOf(address(this));
        shares = balanceAfter - balanceBefore;
        require(shares > 0, "AWKCompoundV2Adapter: zero shares minted");
        assetsDeposited = baseAssetBalanceBefore - IERC20(asset).balanceOf(address(this));
    }

    /// @dev The shares parameter is the cToken amount to redeem; underlying paid out as native ETH is wrapped back
    ///      into the underlying (WETH), so the wallet always receives the underlying token
    function _withdraw(address vault, uint256 shares) internal virtual override returns (uint256 assets) {
        address asset = ICToken(vault).underlying();
        uint256 assetBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 nativeBalanceBefore = address(this).balance;
        uint256 redeemResult = ICToken(vault).redeem(shares);
        require(redeemResult == 0, "AWKCompoundV2Adapter: redeem failed");
        uint256 nativeReceived = address(this).balance - nativeBalanceBefore;
        if (nativeReceived > 0) IWETH(asset).deposit{value: nativeReceived}();
        assets = IERC20(asset).balanceOf(address(this)) - assetBalanceBefore;
    }
}
