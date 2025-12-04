// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockAavePool {
    mapping(address asset => address aToken) public aTokens;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockAToken(aTokens[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken(aTokens[asset]).burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }
}

contract MockAToken is ERC20 {
    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public pool;

    constructor(address underlying, string memory name, string memory symbol) ERC20(name, symbol) {
        UNDERLYING_ASSET_ADDRESS = underlying;
    }

    function setPool(address _pool) external {
        pool = _pool;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == pool, "MockAToken: only pool can mint");
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == pool, "MockAToken: only pool can burn");
        _burn(from, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
