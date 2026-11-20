// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerAaveV3BorrowAdapter} from "../../../src/adapters/AaveV3BorrowAdapter.sol";
import {YieldSeekerAaveV4BorrowAdapter} from "../../../src/adapters/AaveV4BorrowAdapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter} from "../../../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerAgentTransferAdapter} from "../../../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerCompoundV3Adapter} from "../../../src/adapters/CompoundV3Adapter.sol";
import {YieldSeekerERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter} from "../../../src/adapters/MerklAdapter.sol";
import {YieldSeekerMorphoBlueBorrowAdapter} from "../../../src/adapters/MorphoBlueBorrowAdapter.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";

/// @notice A deployed adapter is callable by anyone. These proofs show that, for any caller and any calldata of the
///         given shape, a call made straight to the adapter (rather than through a wallet) never completes one of its operations.
contract AdapterDirectCallHalmos {
    address private erc4626Adapter;
    address private aaveV3Adapter;
    address private compoundV3Adapter;
    address private aaveV3BorrowAdapter;
    address private aaveV4BorrowAdapter;
    address private morphoBlueBorrowAdapter;
    address private uniswapV3SwapAdapter;
    address private aerodromeV2SwapAdapter;
    address private aerodromeCLSwapAdapter;
    address private merklAdapter;
    address private agentTransferAdapter;

    function setUp() public {
        erc4626Adapter = address(new YieldSeekerERC4626Adapter());
        aaveV3Adapter = address(new YieldSeekerAaveV3Adapter());
        compoundV3Adapter = address(new YieldSeekerCompoundV3Adapter());
        aaveV3BorrowAdapter = address(new YieldSeekerAaveV3BorrowAdapter());
        aaveV4BorrowAdapter = address(new YieldSeekerAaveV4BorrowAdapter());
        morphoBlueBorrowAdapter = address(new YieldSeekerMorphoBlueBorrowAdapter());
        uniswapV3SwapAdapter = address(new YieldSeekerUniswapV3SwapAdapter(address(0x1001)));
        aerodromeV2SwapAdapter = address(new YieldSeekerAerodromeV2SwapAdapter(address(0x1002), address(0x1003)));
        aerodromeCLSwapAdapter = address(new YieldSeekerAerodromeCLSwapAdapter(address(0x1004)));
        merklAdapter = address(new YieldSeekerMerklAdapter());
        agentTransferAdapter = address(new YieldSeekerAgentTransferAdapter());
    }

    function check_property10_vaultOperationsNeverCompleteOnADirectCall(bytes4 selector, uint256 amount) external {
        bytes4[3] memory operations = [YieldSeekerERC4626Adapter(erc4626Adapter).deposit.selector, YieldSeekerERC4626Adapter(erc4626Adapter).depositPercentage.selector, YieldSeekerERC4626Adapter(erc4626Adapter).withdraw.selector];
        bool isOperation = selector == operations[0] || selector == operations[1] || selector == operations[2];
        bytes memory data = abi.encodePacked(selector, amount);
        assert(!isOperation || !_succeeds(erc4626Adapter, data));
        assert(!isOperation || !_succeeds(aaveV3Adapter, data));
        assert(!isOperation || !_succeeds(compoundV3Adapter, data));
    }

    function check_property10_borrowOperationsNeverCompleteOnADirectCall(bytes4 selector, bytes32 firstWord, bytes32 secondWord, bytes32 thirdWord, bytes32 fourthWord, bytes32 fifthWord, uint256 amount) external {
        YieldSeekerAaveV3BorrowAdapter operations = YieldSeekerAaveV3BorrowAdapter(aaveV3BorrowAdapter);
        bool takesAmount = selector == operations.supplyCollateral.selector || selector == operations.withdrawCollateral.selector || selector == operations.borrow.selector || selector == operations.repay.selector;
        bytes memory market = abi.encodePacked(firstWord, secondWord, thirdWord, fourthWord, fifthWord);
        bytes memory amountCall = abi.encodePacked(selector, abi.encode(market, amount));
        bytes memory checkpointCall = abi.encodeCall(operations.checkpoint, (market));
        assert(!takesAmount || !_succeeds(aaveV3BorrowAdapter, amountCall));
        assert(!takesAmount || !_succeeds(aaveV4BorrowAdapter, amountCall));
        assert(!takesAmount || !_succeeds(morphoBlueBorrowAdapter, amountCall));
        assert(!_succeeds(aaveV3BorrowAdapter, checkpointCall));
        assert(!_succeeds(aaveV4BorrowAdapter, checkpointCall));
        assert(!_succeeds(morphoBlueBorrowAdapter, checkpointCall));
    }

    function check_property10_swapOperationsNeverCompleteOnADirectCall(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, address firstHop, address secondHop, uint256 routeDetail) external {
        address[] memory path = new address[](2);
        path[0] = firstHop;
        path[1] = secondHop;
        uint256[] memory details = new uint256[](1);
        details[0] = routeDetail;
        bytes memory arguments = abi.encode(sellToken, buyToken, SwapRouteShape({path: path, details: details}), sellAmount, minBuyAmount, deadline);
        assert(!_succeeds(uniswapV3SwapAdapter, abi.encodePacked(YieldSeekerUniswapV3SwapAdapter(uniswapV3SwapAdapter).swap.selector, arguments)));
        assert(!_succeeds(aerodromeV2SwapAdapter, abi.encodePacked(YieldSeekerAerodromeV2SwapAdapter(aerodromeV2SwapAdapter).swap.selector, arguments)));
        assert(!_succeeds(aerodromeCLSwapAdapter, abi.encodePacked(YieldSeekerAerodromeCLSwapAdapter(aerodromeCLSwapAdapter).swap.selector, arguments)));
    }

    function check_property10_claimAndTransferNeverCompleteOnADirectCall(address token, address recipient, uint256 amount, bytes32 proofNode) external {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](1);
        proofs[0][0] = proofNode;
        assert(!_succeeds(merklAdapter, abi.encodeCall(YieldSeekerMerklAdapter(merklAdapter).claim, (tokens, amounts, proofs))));
        assert(!_succeeds(agentTransferAdapter, abi.encodeCall(YieldSeekerAgentTransferAdapter(agentTransferAdapter).transfer, (token, recipient, amount))));
    }

    function _succeeds(address adapter, bytes memory data) private returns (bool success) {
        (success,) = adapter.call(data);
    }
}

struct SwapRouteShape {
    address[] path;
    uint256[] details;
}
