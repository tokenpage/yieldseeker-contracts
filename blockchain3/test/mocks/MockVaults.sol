// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC4626Vault
 * @notice Simple mock ERC4626 vault for testing
 * @dev 1:1 share ratio for simplicity
 */
contract MockERC4626Vault is ERC20 {
    IERC20 public immutable _asset;

    constructor(address asset_, string memory name, string memory symbol) ERC20(name, symbol) {
        _asset = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 ratio
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (owner != msg.sender) {
            // Simplified allowance check
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ERC4626: insufficient allowance");
                _approve(owner, msg.sender, allowed - shares);
            }
        }
        _burn(owner, shares);
        assets = shares; // 1:1 ratio
        _asset.transfer(receiver, assets);
    }
}

/**
 * @title MockAaveV3Pool
 * @notice Simple mock Aave V3 pool for testing
 */
contract MockAaveV3Pool {
    mapping(address => address) public assetToAToken;

    function setAToken(address asset, address aToken) external {
        assetToAToken[asset] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockAToken(assetToAToken[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        uint256 actualAmount = amount == type(uint256).max
            ? MockAToken(assetToAToken[asset]).balanceOf(msg.sender)
            : amount;
        MockAToken(assetToAToken[asset]).burn(msg.sender, actualAmount);
        IERC20(asset).transfer(to, actualAmount);
        return actualAmount;
    }
}

/**
 * @title MockAToken
 * @notice Simple mock aToken for testing
 */
contract MockAToken is ERC20 {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public pool;

    constructor(address asset_, string memory name, string memory symbol) ERC20(name, symbol) {
        UNDERLYING_ASSET_ADDRESS = asset_;
    }

    function setPool(address _pool) external {
        pool = _pool;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "Only pool");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "Only pool");
        _burn(from, amount);
    }
}
