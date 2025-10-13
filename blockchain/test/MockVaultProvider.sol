// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultProvider} from "../src/vaults/IVaultProvider.sol";

/**
 * @title MockVaultProvider
 * @notice Mock vault provider for testing AgentWallet
 */
contract MockVaultProvider is IVaultProvider {
    // Track shares per wallet per vault
    mapping(address vault => mapping(address wallet => uint256 shares)) public shares;

    // Track withdrawable shares (for testing withdrawal limits)
    mapping(address vault => mapping(address wallet => uint256)) public withdrawableShares;

    // Track total assets in vault
    mapping(address vault => uint256) public totalAssets;

    // Track underlying token per vault
    mapping(address vault => address) public underlyingToken;

    // Conversion rate: 1 token = 1 share (for simplicity)
    uint256 public constant SHARE_PRICE = 1e18;

    function deposit(address vault, address token, uint256 amount) external override returns (uint256) {
        // Transfer tokens from caller
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Set underlying token if not set
        if (underlyingToken[vault] == address(0)) {
            underlyingToken[vault] = token;
        }

        // Calculate shares (1:1 for simplicity)
        uint256 newShares = amount;

        // Update state
        shares[vault][msg.sender] += newShares;
        withdrawableShares[vault][msg.sender] += newShares;
        totalAssets[vault] += amount;

        return newShares;
    }

    function withdraw(address vault, uint256 sharesToWithdraw) external override returns (uint256) {
        require(shares[vault][msg.sender] >= sharesToWithdraw, "Insufficient shares");
        require(withdrawableShares[vault][msg.sender] >= sharesToWithdraw, "Insufficient withdrawable shares");

        // Calculate amount (1:1 for simplicity)
        uint256 amount = sharesToWithdraw;

        // Update state
        shares[vault][msg.sender] -= sharesToWithdraw;
        withdrawableShares[vault][msg.sender] -= sharesToWithdraw;
        totalAssets[vault] -= amount;

        // Transfer tokens back to caller
        IERC20(underlyingToken[vault]).transfer(msg.sender, amount);

        return amount;
    }

    function claimRewards(address /* vault */ ) external pure override returns (address[] memory tokens, uint256[] memory amounts) {
        // Return empty arrays for now
        tokens = new address[](0);
        amounts = new uint256[](0);
        return (tokens, amounts);
    }

    function getShareValue(address, /* vault */ uint256 sharesToValue) external pure override returns (uint256) {
        // 1:1 conversion for simplicity
        return sharesToValue;
    }

    function getShareCount(address vault, address wallet) external view override returns (uint256) {
        return shares[vault][wallet];
    }

    function getWithdrawableShareCount(address vault, address wallet) external view override returns (uint256) {
        return withdrawableShares[vault][wallet];
    }

    function getUnderlyingToken(address vault) external view override returns (address) {
        return underlyingToken[vault];
    }

    function getVaultToken(address vault) external pure override returns (address) {
        // Return vault address as the vault token for simplicity
        return vault;
    }

    // Test helper: Set withdrawable shares to simulate withdrawal limits
    function setWithdrawableShares(address vault, address wallet, uint256 amount) external {
        withdrawableShares[vault][wallet] = amount;
    }

    // Test helper: Mint shares directly for testing
    function mintShares(address vault, address wallet, uint256 amount) external {
        shares[vault][wallet] += amount;
        withdrawableShares[vault][wallet] += amount;
    }
}
