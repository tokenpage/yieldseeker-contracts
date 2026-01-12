// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCToken
/// @notice Mock Compound V2 style cToken/mToken for testing adapter integration (Moonwell, etc.)
/// @dev Uses exchange rate based model where cToken * exchangeRate = underlying
contract MockCToken is ERC20 {
    IERC20 private immutable _UNDERLYING;
    uint256 private _exchangeRateStored;
    uint256 private constant EXCHANGE_RATE_SCALE = 1e18;

    constructor(address underlying_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _UNDERLYING = IERC20(underlying_);
        _exchangeRateStored = EXCHANGE_RATE_SCALE; // 1:1 initially
    }

    function underlying() external view returns (address) {
        return address(_UNDERLYING);
    }

    function exchangeRateStored() external view returns (uint256) {
        return _exchangeRateStored;
    }

    function exchangeRateCurrent() external view returns (uint256) {
        return _exchangeRateStored;
    }

    /// @notice Mint cTokens by depositing underlying
    /// @param mintAmount Amount of underlying to deposit
    /// @return 0 on success (Compound V2 error code convention)
    function mint(uint256 mintAmount) external returns (uint256) {
        require(_UNDERLYING.transferFrom(msg.sender, address(this), mintAmount), "Transfer failed");
        uint256 cTokenAmount = (mintAmount * EXCHANGE_RATE_SCALE) / _exchangeRateStored;
        _mint(msg.sender, cTokenAmount);
        return 0; // Success
    }

    /// @notice Redeem cTokens for underlying
    /// @param redeemTokens Amount of cTokens to redeem
    /// @return 0 on success (Compound V2 error code convention)
    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 underlyingAmount = (redeemTokens * _exchangeRateStored) / EXCHANGE_RATE_SCALE;
        _burn(msg.sender, redeemTokens);
        require(_UNDERLYING.transfer(msg.sender, underlyingAmount), "Transfer failed");
        return 0; // Success
    }

    /// @notice Redeem underlying directly
    /// @param redeemAmount Amount of underlying to redeem
    /// @return 0 on success (Compound V2 error code convention)
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        uint256 cTokenAmount = (redeemAmount * EXCHANGE_RATE_SCALE + _exchangeRateStored - 1) / _exchangeRateStored;
        _burn(msg.sender, cTokenAmount);
        require(_UNDERLYING.transfer(msg.sender, redeemAmount), "Transfer failed");
        return 0; // Success
    }

    /// @notice Get underlying balance for an account
    function balanceOfUnderlying(address account) external view returns (uint256) {
        return (balanceOf(account) * _exchangeRateStored) / EXCHANGE_RATE_SCALE;
    }

    /// @notice Simulate yield by increasing exchange rate
    /// @param yieldBps Yield in basis points (100 = 1%)
    function addYield(uint256 yieldBps) external {
        _exchangeRateStored = (_exchangeRateStored * (10000 + yieldBps)) / 10000;
    }

    /// @notice Add underlying tokens to cover yield withdrawals
    function fundYield(uint256 amount) external {
        // For testing: mint underlying tokens to the cToken contract
        // In production, this would come from borrower interest payments
    }

    function decimals() public pure override returns (uint8) {
        return 8; // cTokens typically have 8 decimals
    }
}
