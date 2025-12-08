// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IActionRegistry {
    function isValidTarget(address target) external view returns (bool valid, address adapter);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/**
 * @title AaveV3Adapter
 * @notice Adapter for interacting with Aave V3 pools via delegatecall
 * @dev Called via delegatecall from AgentWallet - executes in wallet context
 */
contract AaveV3Adapter {
    using SafeERC20 for IERC20;

    IActionRegistry public immutable registry;
    address public immutable self;

    event Supplied(address indexed wallet, address indexed pool, address indexed asset, uint256 amount);
    event Withdrawn(address indexed wallet, address indexed pool, address indexed asset, uint256 amount);

    error PoolNotRegistered(address pool);
    error WrongAdapter(address pool, address expectedAdapter);
    error ZeroAmount();

    constructor(address _registry) {
        registry = IActionRegistry(_registry);
        self = address(this);
    }

    function _validatePool(address pool) internal view {
        (bool valid, address adapter) = registry.isValidTarget(pool);
        if (!valid) revert PoolNotRegistered(pool);
        if (adapter != self) revert WrongAdapter(pool, adapter);
    }

    function supply(address pool, address asset, uint256 amount) external {
        _validatePool(pool);
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).forceApprove(pool, amount);
        IAavePool(pool).supply(asset, amount, address(this), 0);
        emit Supplied(address(this), pool, asset, amount);
    }

    function withdraw(address pool, address asset, uint256 amount) external returns (uint256) {
        _validatePool(pool);
        if (amount == 0) revert ZeroAmount();
        uint256 withdrawn = IAavePool(pool).withdraw(asset, amount, address(this));
        emit Withdrawn(address(this), pool, asset, withdrawn);
        return withdrawn;
    }

    function getATokenBalance(address aToken, address wallet) external view returns (uint256) {
        return IAToken(aToken).balanceOf(wallet);
    }
}
