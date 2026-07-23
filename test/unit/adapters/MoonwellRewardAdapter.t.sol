// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {YieldSeekerMoonwellRewardAdapter} from "../../../src/adapters/MoonwellRewardAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract MockMoonwellComptroller {
    IERC20Like public immutable wellToken;
    uint256 public rewardPerMarket;
    bool public shouldRevert;

    constructor(IERC20Like wellToken_) {
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

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract MoonwellRewardAdapterTest is Test {
    YieldSeekerMoonwellRewardAdapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockMoonwellComptroller comptroller;
    MockERC20 baseAsset;
    MockERC20 wellToken;

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        wellToken = new MockERC20("Moonwell", "WELL");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF));
        adapter = new YieldSeekerMoonwellRewardAdapter(address(wellToken));
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        comptroller = new MockMoonwellComptroller(IERC20Like(address(wellToken)));
        wellToken.mint(address(comptroller), 1_000_000e18);
        comptroller.setRewardPerMarket(100e18);
    }

    function test_ClaimReward_TransfersWellAndRecordsFee() public {
        address[] memory mTokens = new address[](2);
        mTokens[0] = address(0x1111);
        mTokens[1] = address(0x2222);

        wallet.executeAdapter(address(adapter), address(comptroller), abi.encodeWithSelector(adapter.claimReward.selector, address(wallet), mTokens));

        assertEq(wellToken.balanceOf(address(wallet)), 200e18);
        assertEq(feeTracker.agentYieldTokenFeesOwed(address(wallet), address(wellToken)), 20e18);
    }

    function test_ClaimReward_RejectsDifferentHolder() public {
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(0x1111);

        vm.expectRevert(abi.encodeWithSignature("InvalidClaimHolder(address)", address(this)));
        wallet.executeAdapter(address(adapter), address(comptroller), abi.encodeWithSelector(adapter.claimReward.selector, address(this), mTokens));
    }

    function test_ClaimReward_RevertPropagates() public {
        comptroller.setShouldRevert(true);
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(0x1111);

        vm.expectRevert();
        wallet.executeAdapter(address(adapter), address(comptroller), abi.encodeWithSelector(adapter.claimReward.selector, address(wallet), mTokens));
    }
}
