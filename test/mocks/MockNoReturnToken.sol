// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice A USDT-style token: transfer, transferFrom and approve return nothing, and approve refuses to change a
///         non-zero allowance to another non-zero value
contract MockNoReturnToken {
    string public constant name = "No Return";
    string public constant symbol = "NORET";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(amount > 0, "zero transfer");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "reset the allowance first");
        allowance[msg.sender][spender] = amount;
    }
}

contract PlainERC4626Vault is ERC4626 {
    constructor(address asset_) ERC4626(IERC20(asset_)) ERC20("Plain Vault", "pVAULT") {}
}
