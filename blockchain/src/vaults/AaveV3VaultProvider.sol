// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVaultProvider} from "./IVaultProvider.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken is IERC20 {
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @title AaveV3VaultProvider
 * @notice Vault provider wrapper for Aave V3 lending pools
 * @dev Wraps Aave V3 supply/withdraw operations
 *      Deploy once and use for all Aave V3 pools
 *      In Aave V3, vaultAddress is the aToken address
 */
contract AaveV3VaultProvider is IVaultProvider {
    /// @notice Aave V3 Pool contract (shared across all aTokens)
    IAavePool public immutable aavePool;

    /// @notice Address of the YieldSeeker system (AgentController calls only)
    address public immutable yieldSeekerSystem;

    error NotAuthorized();
    error InvalidAddress();
    error InvalidToken();
    error SupplyFailed();
    error WithdrawFailed();

    modifier onlyYieldSeeker() {
        if (msg.sender != yieldSeekerSystem) revert NotAuthorized();
        _;
    }

    constructor(address _aavePool, address _yieldSeekerSystem) {
        if (_aavePool == address(0) || _yieldSeekerSystem == address(0)) {
            revert InvalidAddress();
        }

        aavePool = IAavePool(_aavePool);
        yieldSeekerSystem = _yieldSeekerSystem;
    }

    /**
     * @inheritdoc IVaultProvider
     * @dev For Aave V3, vaultAddress is the aToken address
     */
    function deposit(address vaultAddress, address token, uint256 amount) external onlyYieldSeeker returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();

        IAToken aToken = IAToken(vaultAddress);
        IERC20 underlyingToken = IERC20(token);

        // Get aToken balance before
        uint256 aTokenBefore = aToken.balanceOf(msg.sender);

        // Transfer tokens from agent wallet to this provider
        bool success = underlyingToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert SupplyFailed();

        // Approve Aave pool to spend tokens
        underlyingToken.approve(address(aavePool), amount);

        // Supply to Aave on behalf of agent wallet
        aavePool.supply(token, amount, msg.sender, 0);

        // Calculate shares received (aToken balance increase)
        uint256 aTokenAfter = aToken.balanceOf(msg.sender);
        shares = aTokenAfter - aTokenBefore;

        if (shares == 0) revert SupplyFailed();
    }

    /**
     * @inheritdoc IVaultProvider
     * @dev For Aave V3, vaultAddress is the aToken address
     */
    function withdraw(address vaultAddress, uint256 shares) external onlyYieldSeeker returns (uint256 amount) {
        if (vaultAddress == address(0)) revert InvalidAddress();

        IAToken aToken = IAToken(vaultAddress);
        address underlyingToken = aToken.UNDERLYING_ASSET_ADDRESS();

        // Withdraw from Aave (shares = aToken amount in Aave V3)
        amount = aavePool.withdraw(underlyingToken, shares, msg.sender);
        if (amount == 0) revert WithdrawFailed();
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function claimRewards(address /* vaultAddress */ ) external view onlyYieldSeeker returns (address[] memory tokens, uint256[] memory amounts) {
        // Aave V3 doesn't have separate reward claiming in the pool contract
        // Rewards are typically claimed via separate IncentivesController
        // Return empty arrays for basic implementation
        tokens = new address[](0);
        amounts = new uint256[](0);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getShareValue(address, /* vaultAddress */ uint256 shares) external pure returns (uint256 value) {
        // In Aave V3, aToken is 1:1 with underlying (with yield accrual)
        // shares = aToken amount = underlying amount
        return shares;
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getUnderlyingToken(address vaultAddress) external view returns (address token) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IAToken aToken = IAToken(vaultAddress);
        return aToken.UNDERLYING_ASSET_ADDRESS();
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getShareCount(address vaultAddress, address wallet) external view returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IAToken aToken = IAToken(vaultAddress);
        return aToken.balanceOf(wallet);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getWithdrawableShareCount(address vaultAddress, address wallet) external view returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IAToken aToken = IAToken(vaultAddress);
        // In Aave V3, all aToken balance is assumed to be withdrawable
        // (subject to pool liquidity which is checked on-chain during withdrawal)
        return aToken.balanceOf(wallet);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getVaultToken(address vaultAddress) external view returns (address vaultToken) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        return vaultAddress;
    }
}
