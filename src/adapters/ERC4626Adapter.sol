// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../IAgentWallet.sol";
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

    /**
     * @notice Override execute to handle vault operations
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable override returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.deposit.selector) {
            uint256 amount = abi.decode(data[4:], (uint256));
            uint256 shares = _depositInternal(target, amount);
            return abi.encode(shares);
        }
        if (selector == this.withdraw.selector) {
            uint256 shares = abi.decode(data[4:], (uint256));
            uint256 assets = _withdrawInternal(target, shares);
            return abi.encode(assets);
        }
        revert UnknownOperation();
    }

    // ============ Vault Operations ============

    /**
     * @notice Deposit assets into an ERC4626 vault (public interface, should not be called directly)
     */
    function deposit(uint256 amount) external pure returns (uint256 shares) {
        revert("Use execute");
    }

    /**
     * @notice Internal deposit implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _depositInternal(address vault, uint256 amount) internal returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this));
        _feeLedger().recordAgentVaultShareDeposit(vault, amount, shares);
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Withdraw assets from an ERC4626 vault (public interface, should not be called directly)
     */
    function withdraw(uint256 shares) external pure returns (uint256 assets) {
        revert("Use execute");
    }

    /**
     * @notice Internal withdraw implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _withdrawInternal(address vault, uint256 shares) internal returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        _feeLedger().recordAgentVaultShareWithdraw(vault, shares, assets);
        emit Withdrawn(address(this), vault, shares, assets);
    }
}
