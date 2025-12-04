// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC4626 is ERC20 {
    IERC20 public immutable _asset;

    constructor(address asset_) ERC20("Mock Vault", "mVAULT") {
        _asset = IERC20(asset_);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        _asset.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) {
            revert("MockERC4626: not owner");
        }
        assets = shares;
        _burn(owner, shares);
        _asset.transfer(receiver, assets);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
