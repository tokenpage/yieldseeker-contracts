// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKZeroXAdapter} from "../../../src/agentwalletkit/adapters/AWKZeroXAdapter.sol";
import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {YieldSeekerZeroXAdapter} from "../../../src/adapters/ZeroXAdapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract MockZeroXTarget {
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public lastValue;
    uint256 public configuredBuyAmount;
    bool public shouldRevert;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function swap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) external payable {
        if (shouldRevert) revert("swap failed");
        lastValue = msg.value;
        if (sellToken != NATIVE_TOKEN) {
            require(MockERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount), "TransferFrom failed");
        }
        uint256 buyAmount = configuredBuyAmount == 0 ? minBuyAmount : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, buyAmount), "Transfer failed");
    }
}

contract ZeroXAdapterTest is Test {
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    YieldSeekerZeroXAdapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    MockERC20 sellToken;
    MockZeroXTarget target;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        sellToken = new MockERC20("Mock Token", "mTKN");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF));
        target = new MockZeroXTarget();
        adapter = new YieldSeekerZeroXAdapter(address(target));
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        baseAsset.mint(address(target), 1_000_000e6);
        sellToken.mint(address(wallet), 1_000e18);
    }

    function test_Execute_SwapTokens_Succeeds() public {
        target.setBuyAmount(500e6);
        bytes memory data = abi.encodeWithSelector(
            adapter.swap.selector,
            address(sellToken),
            address(baseAsset),
            uint256(100e18),
            uint256(400e6),
            abi.encodeWithSelector(MockZeroXTarget.swap.selector, address(sellToken), address(baseAsset), uint256(100e18), uint256(400e6)),
            uint256(0)
        );
        bytes memory result = wallet.executeAdapter(address(adapter), address(target), data);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 500e6);
        assertEq(sellToken.balanceOf(address(wallet)), 900e18);
        assertEq(baseAsset.balanceOf(address(wallet)), 500e6);
    }

    function test_Execute_Swap_RevertsOnLowOutput() public {
        target.setBuyAmount(100e6);
        bytes memory data = abi.encodeWithSelector(
            adapter.swap.selector,
            address(sellToken),
            address(baseAsset),
            uint256(100e18),
            uint256(150e6),
            abi.encodeWithSelector(MockZeroXTarget.swap.selector, address(sellToken), address(baseAsset), uint256(100e18), uint256(150e6)),
            uint256(0)
        );
        vm.expectRevert(abi.encodeWithSelector(AWKZeroXAdapter.InsufficientOutput.selector, uint256(100e6), uint256(150e6)));
        wallet.executeAdapter(address(adapter), address(target), data);
    }

    function test_Execute_Swap_RevertsOnZeroAmounts() public {
        bytes memory data = abi.encodeWithSelector(
            adapter.swap.selector, address(sellToken), address(baseAsset), uint256(0), uint256(0), abi.encodeWithSelector(MockZeroXTarget.swap.selector, address(sellToken), address(baseAsset), uint256(0), uint256(0)), uint256(0)
        );
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(target), data);
    }

    function test_Execute_Swap_RevertBubble() public {
        target.setRevert(true);
        bytes memory data = abi.encodeWithSelector(
            adapter.swap.selector,
            address(sellToken),
            address(baseAsset),
            uint256(10e18),
            uint256(10e6),
            abi.encodeWithSelector(MockZeroXTarget.swap.selector, address(sellToken), address(baseAsset), uint256(10e18), uint256(10e6)),
            uint256(0)
        );
        vm.expectRevert();
        wallet.executeAdapter(address(adapter), address(target), data);
    }

    function test_Execute_Swap_NativeUsesSellAmount() public {
        target.setBuyAmount(200e6);
        bytes memory data = abi.encodeWithSelector(
            adapter.swap.selector,
            NATIVE_TOKEN,
            address(baseAsset),
            uint256(1 ether),
            uint256(100e6),
            abi.encodeWithSelector(MockZeroXTarget.swap.selector, NATIVE_TOKEN, address(baseAsset), uint256(1 ether), uint256(100e6)),
            uint256(10 ether)
        );
        vm.deal(address(wallet), 2 ether);
        bytes memory result = wallet.executeAdapter(address(adapter), address(target), data);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 200e6);
        assertEq(target.lastValue(), 1 ether);
    }
}
