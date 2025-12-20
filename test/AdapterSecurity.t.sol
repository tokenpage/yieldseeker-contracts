// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerZeroXAdapter} from "../src/adapters/ZeroXAdapter.sol";
import {YieldSeekerMerklAdapter} from "../src/adapters/MerklAdapter.sol";
import {YieldSeekerAdapter} from "../src/adapters/Adapter.sol";
import {Test} from "forge-std/Test.sol";

contract AdapterSecurityTest is Test {
    YieldSeekerERC4626Adapter erc4626Adapter;
    YieldSeekerZeroXAdapter zeroXAdapter;
    YieldSeekerMerklAdapter merklAdapter;

    function setUp() public {
        erc4626Adapter = new YieldSeekerERC4626Adapter();
        zeroXAdapter = new YieldSeekerZeroXAdapter(address(0x123)); // allowance target
        merklAdapter = new YieldSeekerMerklAdapter();
    }

    /**
     * @notice Test that direct calls to ERC4626Adapter.execute() are blocked
     */
    function test_RevertOnDirectCall_ERC4626Adapter() public {
        bytes memory data = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);
        vm.expectRevert(YieldSeekerAdapter.DirectCallNotAllowed.selector);
        erc4626Adapter.execute(address(0x456), data);
    }

    /**
     * @notice Test that direct calls to ZeroXAdapter.execute() are blocked
     */
    function test_RevertOnDirectCall_ZeroXAdapter() public {
        bytes memory data = abi.encodeWithSelector(
            zeroXAdapter.swap.selector,
            address(0x111), // sellToken
            address(0x222), // buyToken
            100e6, // sellAmount
            90e6, // minBuyAmount
            hex"", // swapCallData
            0 // value
        );
        vm.expectRevert(YieldSeekerAdapter.DirectCallNotAllowed.selector);
        zeroXAdapter.execute(address(0x456), data);
    }

    /**
     * @notice Test that direct calls to MerklAdapter.execute() are blocked
     */
    function test_RevertOnDirectCall_MerklAdapter() public {
        address[] memory users = new address[](1);
        users[0] = address(this);
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x789);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        
        bytes memory data = abi.encodeWithSelector(
            merklAdapter.claim.selector,
            users,
            tokens,
            amounts,
            proofs
        );
        
        vm.expectRevert(YieldSeekerAdapter.DirectCallNotAllowed.selector);
        merklAdapter.execute(address(0x456), data);
    }

    /**
     * @notice Test that calls from different msg.sender still fail (it's about address(this), not msg.sender)
     */
    function test_RevertOnDirectCall_DifferentCaller() public {
        bytes memory data = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100e6);
        
        vm.prank(address(0x999));
        vm.expectRevert(YieldSeekerAdapter.DirectCallNotAllowed.selector);
        erc4626Adapter.execute(address(0x456), data);
    }
}
