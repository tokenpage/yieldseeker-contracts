// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3, YieldSeekerStorageV1} from "../../src/AgentWalletV3.sol";
import {AWKAdapterRegistry} from "../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AgentWalletStorageV3} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AgentWalletHarness is YieldSeekerAgentWalletV3 {
    address private constant OWNER = address(0xA11CE);
    address private constant OPERATOR = address(0xB0B);
    mapping(address => uint256) private _balances;

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
        yieldSeeker.baseAsset = IERC20(address(this));
        yieldSeeker.feeTracker = YieldSeekerFeeTracker(address(this));
        yieldSeeker.swapPolicy = IYieldSeekerSwapPolicy(address(0));
        _balances[address(this)] = 1_000_000;
    }

    function baseAsset() public pure override returns (IERC20) {
        return IERC20(address(this));
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
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(msg.sender == address(this));
        _balances[msg.sender] -= amount;
        _balances[recipient] += amount;
        return true;
    }

    function operatorListHash() external view returns (bytes32) {
        return keccak256(abi.encode(AgentWalletStorageV3.getLayout().agentOperators));
    }

    function currentImplementation() external view returns (address implementation) {
        assembly {
            implementation := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
        }
    }
}
