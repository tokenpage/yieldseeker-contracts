// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockAaveV3Pool
/// @notice Mock Aave V3 Pool for testing adapter integration
contract MockAaveV3Pool {
    IERC20 private immutable _BASE_ASSET;
    MockAToken private immutable _A_TOKEN;

    constructor(address baseAsset_) {
        _BASE_ASSET = IERC20(baseAsset_);
        _A_TOKEN = new MockAToken(baseAsset_, address(this));
    }

    function aToken() external view returns (address) {
        return address(_A_TOKEN);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(_BASE_ASSET), "Invalid asset");
        require(_BASE_ASSET.transferFrom(msg.sender, address(_A_TOKEN), amount), "Transfer failed");
        _A_TOKEN.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(_BASE_ASSET), "Invalid asset");
        _A_TOKEN.burn(msg.sender, amount);
        _A_TOKEN.transferUnderlying(to, amount);
        return amount;
    }
}

/// @title MockAToken
/// @notice Mock Aave aToken for testing - rebasing token where balance = underlying value
contract MockAToken is IERC20 {
    string public constant name = "Mock aToken";
    string public constant symbol = "aToken";
    uint8 public constant decimals = 6;

    address public immutable UNDERLYING_ASSET_ADDRESS;
    address public immutable POOL;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor(address underlying_, address pool_) {
        UNDERLYING_ASSET_ADDRESS = underlying_;
        POOL = pool_;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == POOL, "Only pool can mint");
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == POOL, "Only pool can burn");
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transferUnderlying(address to, uint256 amount) external {
        require(msg.sender == POOL, "Only pool can transfer underlying");
        IERC20(UNDERLYING_ASSET_ADDRESS).transfer(to, amount);
    }

    /// @notice Simulate yield by minting extra aTokens
    function addYield(address account, uint256 amount) external {
        _balances[account] += amount;
        _totalSupply += amount;
    }
}
