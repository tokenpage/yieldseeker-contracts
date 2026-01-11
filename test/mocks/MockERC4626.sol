// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC4626
/// @notice Mock ERC4626 vault for testing adapter integration with realistic yield generation
contract MockERC4626 is ERC20, IERC4626 {
    IERC20 private immutable _ASSET;
    uint256 private _accumulatedYield;

    constructor(address asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _ASSET = IERC20(asset_);
        _accumulatedYield = 0;
    }

    /// @notice Add yield to the vault (simulates external yield generation)
    function addYield(uint256 amount) external {
        _accumulatedYield += amount;
    }

    /// @notice Get total assets including accumulated yield
    function asset() external view override returns (address) {
        return address(_ASSET);
    }

    /// @notice Get total assets in vault including yield
    function totalAssets() external view override returns (uint256) {
        return _ASSET.balanceOf(address(this));
    }

    /// @notice Convert assets to shares, accounting for accumulated yield
    function convertToShares(uint256 assets) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return assets;

        // shares = assets * totalShares / totalAssets
        return (assets * totalShares) / totalAssets_;
    }

    /// @notice Convert shares to assets, accounting for accumulated yield
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return shares;

        // assets = shares * totalAssets / totalShares
        return (shares * totalAssets_) / totalShares;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return assets;
        return (assets * totalShares) / totalAssets_;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this)) + _accumulatedYield;
        uint256 totalShares = totalSupply();

        if (totalShares == 0) {
            shares = assets;
        } else {
            shares = (assets * totalShares) / totalAssets_;
        }

        require(_ASSET.transferFrom(msg.sender, address(this), assets), "Transfer failed");
        _mint(receiver, shares);
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this)) + _accumulatedYield;
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return shares;
        return (shares * totalAssets_) / totalShares;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this)) + _accumulatedYield;
        uint256 totalShares = totalSupply();

        if (totalShares == 0) {
            assets = shares;
        } else {
            assets = (shares * totalAssets_) / totalShares;
        }

        require(_ASSET.transferFrom(msg.sender, address(this), assets), "Transfer failed");
        _mint(receiver, shares);
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        uint256 shares = balanceOf(owner);

        if (totalShares == 0) return 0;
        return (shares * totalAssets_) / totalShares;
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return assets;
        return (assets * totalShares) / totalAssets_;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) {
            shares = assets;
        } else {
            shares = (assets * totalShares) / totalAssets_;
        }

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        require(_ASSET.transfer(receiver, assets), "Transfer failed");
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) return shares;
        return (shares * totalAssets_) / totalShares;
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        uint256 totalAssets_ = _ASSET.balanceOf(address(this));
        uint256 totalShares = totalSupply();

        if (totalShares == 0) {
            assets = shares;
        } else {
            assets = (shares * totalAssets_) / totalShares;
        }

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        require(_ASSET.transfer(receiver, assets), "Transfer failed");
    }
}
