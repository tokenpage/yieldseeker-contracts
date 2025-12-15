// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

contract AaveV3Adapter {
    using SafeERC20 for IERC20;

    event Supplied(address indexed wallet, address indexed pool, address indexed asset, uint256 amount);
    event Withdrawn(address indexed wallet, address indexed pool, address indexed asset, uint256 amount);

    error ZeroAmount();

    function supply(address pool, address asset, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).forceApprove(pool, amount);
        IAavePool(pool).supply(asset, amount, address(this), 0);
        emit Supplied(address(this), pool, asset, amount);
    }

    function withdraw(address pool, address asset, uint256 amount) external returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        uint256 withdrawn = IAavePool(pool).withdraw(asset, amount, address(this));
        emit Withdrawn(address(this), pool, asset, withdrawn);
        return withdrawn;
    }

    function getATokenBalance(address aToken, address wallet) external view returns (uint256) {
        return IAToken(aToken).balanceOf(wallet);
    }
}
