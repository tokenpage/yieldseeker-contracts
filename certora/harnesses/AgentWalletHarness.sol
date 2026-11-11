// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3, YieldSeekerStorageV1} from "../../src/AgentWalletV3.sol";
import {AWKAdapterRegistry} from "../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AgentWalletStorageV3} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBaseAssetBalanceRecorder {
    function recordBaseAssetTransfer(address sender, address recipient, uint256 amount) external;
}

contract MockBaseAsset {
    mapping(address account => uint256) private _balances;
    address private immutable _wallet;

    constructor(address holder, uint256 initialBalance) {
        _wallet = holder;
        _balances[holder] = initialBalance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        uint256 senderBalance = _balances[msg.sender];
        require(senderBalance >= amount);
        _balances[msg.sender] = senderBalance - amount;
        _balances[recipient] += amount;

        if (msg.sender == _wallet || recipient == _wallet) {
            IBaseAssetBalanceRecorder(_wallet).recordBaseAssetTransfer(msg.sender, recipient, amount);
        }
        return true;
    }
}

contract AgentWalletHarness is YieldSeekerAgentWalletV3 {
    address private constant OWNER = address(0xA11CE);
    address private constant OPERATOR = address(0xB0B);
    MockBaseAsset private immutable _baseAssetToken;
    uint256 private _walletBaseAssetBalance;

    constructor() YieldSeekerAgentWalletV3(address(this)) {
        AgentWalletStorageV3.Layout storage wallet = AgentWalletStorageV3.getLayout();
        wallet.owner = OWNER;
        wallet.ownerAgentIndex = 7;
        wallet.agentProfile = keccak256("certora-profile");
        wallet.adapterRegistry = AWKAdapterRegistry(address(this));

        address[] memory operators = new address[](1);
        operators[0] = OPERATOR;
        _setAgentOperators(operators);
        YieldSeekerStorageV1.Layout storage yieldSeeker = YieldSeekerStorageV1.getLayout();

        uint256 initialBaseAssetBalance = 1_000_000;
        _baseAssetToken = new MockBaseAsset(address(this), initialBaseAssetBalance);
        _walletBaseAssetBalance = initialBaseAssetBalance;
        yieldSeeker.baseAsset = IERC20(address(_baseAssetToken));
        yieldSeeker.feeTracker = YieldSeekerFeeTracker(address(this));
        yieldSeeker.swapPolicy = IYieldSeekerSwapPolicy(address(0));
    }

    function agentWalletImplementation() external view returns (address) {
        return address(this);
    }

    function adapterRegistry(bytes32) external view returns (address) {
        return address(this);
    }

    function feeTracker(bytes32) external view returns (YieldSeekerFeeTracker) {
        return YieldSeekerFeeTracker(address(this));
    }

    function swapPolicy(bytes32) external pure returns (IYieldSeekerSwapPolicy) {
        return IYieldSeekerSwapPolicy(address(0));
    }

    function balanceOf(address account) external view returns (uint256) {
        return account == address(this) ? _walletBaseAssetBalance : 0;
    }

    function recordBaseAssetTransfer(address sender, address recipient, uint256 amount) external {
        require(msg.sender == address(_baseAssetToken));
        if (sender == address(this)) _walletBaseAssetBalance -= amount;
        if (recipient == address(this)) _walletBaseAssetBalance += amount;
    }

    function currentImplementation() external view returns (address implementation) {
        assembly {
            implementation := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
        }
    }

    function walletInitialized() external view returns (bool) {
        return _getInitializedVersion() != 0;
    }
}
