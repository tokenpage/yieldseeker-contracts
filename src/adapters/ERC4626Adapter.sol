// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IERC4626
 * @notice Minimal ERC4626 interface
 */
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

contract YieldSeekerERC4626Adapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    error ZeroAmount();
    error UnknownOperation();

    // ============ Standard Adapter Entry Point ============

    /**
     * @notice Standard entry point for all adapter logic
     * @param target The vault address
     * @param data The operation data (encoded deposit or withdraw call)
     */
    function execute(address target, bytes calldata data) external payable override returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.deposit.selector) {
            uint256 amount = abi.decode(data[4:], (uint256));
            uint256 shares = _deposit(target, amount);
            return abi.encode(shares);
        }
        if (selector == this.withdraw.selector) {
            uint256 shares = abi.decode(data[4:], (uint256));
            uint256 assets = _withdraw(target, shares);
            return abi.encode(assets);
        }
        revert UnknownOperation();
    }

    // ============ Vault Operations (Internal) ============

    /**
     * @notice Deposit assets into an ERC4626 vault
     * @param amount Amount of assets to deposit
     * @return shares Amount of vault shares received
     */
    function deposit(uint256 amount) external pure returns (uint256 shares) {
        revert("Use execute");
    }

    function _deposit(address vault, uint256 amount) internal returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this));
        _feeLedger().recordVaultShareDeposit(vault, amount, shares);
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Withdraw assets from an ERC4626 vault
     * @param shares Amount of shares to redeem
     * @return assets Amount of underlying assets received
     */
    function withdraw(uint256 shares) external pure returns (uint256 assets) {
        revert("Use execute");
    }

    function _withdraw(address vault, uint256 shares) internal returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        _feeLedger().recordVaultShareWithdraw(vault, shares, assets);
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
