// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCompoundV3Comet
/// @notice Mock Compound V3 Comet market for testing adapter integration
/// @dev Compound V3 uses rebasing balance where balance directly represents underlying value
contract MockCompoundV3Comet {
    IERC20 private immutable _BASE_TOKEN;
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;

    constructor(address baseToken_) {
        _BASE_TOKEN = IERC20(baseToken_);
    }

    function baseToken() external view returns (address) {
        return address(_BASE_TOKEN);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function supply(address asset, uint256 amount) external {
        require(asset == address(_BASE_TOKEN), "Invalid asset");
        require(_BASE_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        _balances[msg.sender] += amount;
        _totalSupply += amount;
    }

    function supplyTo(address to, address asset, uint256 amount) external {
        require(asset == address(_BASE_TOKEN), "Invalid asset");
        require(_BASE_TOKEN.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        _balances[to] += amount;
        _totalSupply += amount;
    }

    function withdraw(address asset, uint256 amount) external {
        require(asset == address(_BASE_TOKEN), "Invalid asset");
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        require(_BASE_TOKEN.transfer(msg.sender, amount), "Transfer failed");
    }

    function withdrawTo(address to, address asset, uint256 amount) external {
        require(asset == address(_BASE_TOKEN), "Invalid asset");
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
        require(_BASE_TOKEN.transfer(to, amount), "Transfer failed");
    }

    /// @notice Simulate yield by increasing a user's balance
    function addYield(address account, uint256 amount) external {
        _balances[account] += amount;
        _totalSupply += amount;
        // Note: In real Compound V3, yield comes from actual interest accrual
        // For testing, we just mint extra base tokens to cover withdrawals
    }

    /// @notice Add underlying tokens to cover yield withdrawals
    function fundYield(uint256 amount) external {
        // This simulates protocol revenue that backs the yield
        // In tests, mint base tokens to the comet contract
    }
}
