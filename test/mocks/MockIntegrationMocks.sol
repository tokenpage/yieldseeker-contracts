// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IAerodromeCLSwapRouter} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {IAerodromeV2Router} from "../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {IUniswapV3SwapRouter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {MockERC20} from "./MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockMerklDistributor {
    struct Claim {
        uint208 amount;
        uint48 timestamp;
        bytes32 merkleRoot;
    }

    bool public shouldRevert;
    mapping(address user => mapping(address token => Claim)) public claimed;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata) external {
        if (shouldRevert) revert("claim failed");
        require(users.length == tokens.length && amounts.length == tokens.length, "Length mismatch");
        for (uint256 i = 0; i < tokens.length; i++) {
            Claim storage previous = claimed[users[i]][tokens[i]];
            uint256 toSend = amounts[i] - previous.amount;
            previous.amount = uint208(amounts[i]);
            previous.timestamp = uint48(block.timestamp);
            if (toSend != 0) require(MockERC20(tokens[i]).transfer(users[i], toSend), "Transfer failed");
        }
    }
}

contract MockMoonwellComptroller {
    IERC20 public immutable wellToken;
    uint256 public rewardPerMarket;
    bool public shouldRevert;

    constructor(IERC20 wellToken_) {
        wellToken = wellToken_;
    }

    function setRewardPerMarket(uint256 amount) external {
        rewardPerMarket = amount;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function claimReward(address holder, address[] calldata mTokens) external {
        if (shouldRevert) revert("claim failed");
        for (uint256 i = 0; i < mTokens.length; i++) {
            require(wellToken.transfer(holder, rewardPerMarket), "Transfer failed");
        }
    }
}

contract MockUniswapV3Router {
    uint256 public configuredBuyAmount;
    bool public shouldRevert;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (shouldRevert) revert("swap failed");
        (address sellToken, address buyToken) = _decodePathEndpoints(params.path);
        require(MockERC20(sellToken).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed");
        amountOut = configuredBuyAmount == 0 ? params.amountOutMinimum : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, amountOut), "Transfer failed");
    }

    function _decodePathEndpoints(bytes memory path) internal pure returns (address firstToken, address lastToken) {
        require(path.length >= 43, "invalid path");
        assembly {
            firstToken := shr(96, mload(add(path, 0x20)))
            lastToken := shr(96, mload(add(add(path, 0x20), sub(mload(path), 20))))
        }
    }
}

contract MockAerodromeV2Router {
    uint256 public configuredBuyAmount;
    bool public shouldRevert;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, IAerodromeV2Router.Route[] memory routes, address, uint256) external returns (uint256[] memory amounts) {
        if (shouldRevert) revert("swap failed");
        require(routes.length > 0, "invalid routes");
        address sellToken = routes[0].from;
        address buyToken = routes[routes.length - 1].to;
        require(MockERC20(sellToken).transferFrom(msg.sender, address(this), amountIn), "TransferFrom failed");
        uint256 amountOut = configuredBuyAmount == 0 ? amountOutMin : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, amountOut), "Transfer failed");
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = amountOut;
    }
}

contract MockAerodromeCLRouter {
    uint256 public configuredBuyAmount;
    bool public shouldRevert;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function exactInput(IAerodromeCLSwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (shouldRevert) revert("swap failed");
        (address sellToken, address buyToken) = _decodePathEndpoints(params.path);
        require(MockERC20(sellToken).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed");
        amountOut = configuredBuyAmount == 0 ? params.amountOutMinimum : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, amountOut), "Transfer failed");
    }

    function _decodePathEndpoints(bytes memory path) internal pure returns (address firstToken, address lastToken) {
        require(path.length >= 43, "invalid path");
        assembly {
            firstToken := shr(96, mload(add(path, 0x20)))
            lastToken := shr(96, mload(add(add(path, 0x20), sub(mload(path), 20))))
        }
    }
}
