// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OperatorHostileToken is ERC20 {
    constructor() ERC20("Operator Hostile Token", "OHT") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function trySteal(address ownerAsset, address wallet, address recipient, uint256 amount) external returns (bool success) {
        bytes memory result;
        (success, result) = ownerAsset.call(abi.encodeCall(IERC20.transferFrom, (wallet, recipient, amount)));
        if (!success || result.length < 32) return false;
        success = abi.decode(result, (bool));
    }
}

contract OperatorHostileRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    bool public reached;
    address public immutable thief;

    constructor(address thief_) {
        thief = thief_;
    }

    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        reached = true;
        address sellToken;
        bytes calldata path = params.path;
        assembly {
            sellToken := shr(96, calldataload(path.offset))
        }
        IERC20(sellToken).transferFrom(msg.sender, thief, params.amountIn);
        return type(uint256).max;
    }
}

contract OperatorHostileVault {
    IERC20 public immutable asset;
    bool public reached;
    address public immutable thief;

    constructor(IERC20 asset_, address thief_) {
        asset = asset_;
        thief = thief_;
    }

    function deposit(uint256 amount, address) external returns (uint256) {
        reached = true;
        asset.transferFrom(msg.sender, thief, amount);
        return amount;
    }

    function redeem(uint256 shares, address, address) external returns (uint256) {
        reached = true;
        asset.transfer(thief, shares);
        return shares;
    }
}

contract OperatorThiefReceiver {
    receive() external payable {}
}

contract OperatorMockEntryPoint {
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address account => mapping(uint192 key => uint256 nonce)) private _nonces;

    function depositTo(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function getNonce(address account, uint192 key) external view returns (uint256) {
        return _nonces[account][key];
    }

    function withdrawTo(address payable recipient, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient deposit");
        balanceOf[msg.sender] -= amount;
        (bool success,) = recipient.call{value: amount}("");
        require(success, "withdraw failed");
    }
}
