// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceFeed, InvalidPrice, NoPriceSource, SequencerDown, StalePrice, YieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockFeePriceFeed} from "../mocks/MockFeePriceFeed.sol";
import {Test} from "forge-std/Test.sol";

contract PriceOracleTest is Test {
    address internal admin = makeAddr("admin");
    address internal emergencyAdmin = makeAddr("emergencyAdmin");
    address internal stranger = makeAddr("stranger");

    YieldSeekerPriceOracle internal oracle;
    MockERC20WithDecimals internal weth;
    MockERC20WithDecimals internal usdc;
    MockFeePriceFeed internal feed;
    MockFeePriceFeed internal sequencerFeed;

    function setUp() public {
        vm.warp(2 hours);
        uint256 now_ = vm.getBlockTimestamp();
        sequencerFeed = new MockFeePriceFeed(0, 0, now_ - 1 hours - 1);
        oracle = new YieldSeekerPriceOracle(admin, emergencyAdmin, IPriceFeed(address(sequencerFeed)));
        weth = new MockERC20WithDecimals("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        feed = new MockFeePriceFeed(8, 123_456_789, now_);
    }

    function testGetPriceScalesFeedDecimalsToEighteen() public {
        vm.prank(admin);
        oracle.setSource(address(weth), IPriceFeed(address(feed)), 1 days);

        assertEq(oracle.getPrice(address(weth)), 1_234_567_890_000_000_000);
    }

    function testSequencerStatusZeroStartedAtAndGracePeriodBlockPrices() public {
        uint256 now_ = vm.getBlockTimestamp();

        sequencerFeed.setRoundData(1, now_ - 1 hours - 1, now_);
        vm.expectRevert(SequencerDown.selector);
        oracle.getPrice(address(weth));

        sequencerFeed.setRoundData(0, 0, now_);
        vm.expectRevert(SequencerDown.selector);
        oracle.getPrice(address(weth));

        sequencerFeed.setRoundData(0, now_, now_);
        vm.expectRevert(SequencerDown.selector);
        oracle.getPrice(address(weth));

        sequencerFeed.setRoundData(0, now_ - 1 hours + 1, now_);
        vm.expectRevert(SequencerDown.selector);
        oracle.getPrice(address(weth));
    }

    function testMissingSourceInvalidPricesAndStalePricesRevert() public {
        vm.expectRevert(abi.encodeWithSelector(NoPriceSource.selector, address(weth)));
        oracle.getPrice(address(weth));

        vm.prank(admin);
        oracle.setSource(address(weth), IPriceFeed(address(feed)), 10);

        uint256 now_ = vm.getBlockTimestamp();
        feed.setPrice(0, now_);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, address(weth), int256(0)));
        oracle.getPrice(address(weth));

        feed.setPrice(-1, now_);
        vm.expectRevert(abi.encodeWithSelector(InvalidPrice.selector, address(weth), int256(-1)));
        oracle.getPrice(address(weth));

        uint256 updatedAt = vm.getBlockTimestamp();
        feed.setPrice(1e8, updatedAt);
        vm.warp(updatedAt + 11);
        vm.expectRevert(abi.encodeWithSelector(StalePrice.selector, address(weth), updatedAt, 10));
        oracle.getPrice(address(weth));
    }

    function testQuoteConvertsAcrossTokenDecimalsAndUsdPrices() public {
        uint256 now_ = vm.getBlockTimestamp();
        MockFeePriceFeed wethFeed = new MockFeePriceFeed(8, 3_000e8, now_);
        MockFeePriceFeed usdcFeed = new MockFeePriceFeed(8, 1e8, now_);

        vm.startPrank(admin);
        oracle.setSource(address(weth), IPriceFeed(address(wethFeed)), 1 days);
        oracle.setSource(address(usdc), IPriceFeed(address(usdcFeed)), 1 days);
        vm.stopPrank();

        assertEq(oracle.quote(address(weth), address(usdc), 1e18), 3_000e6);
    }

    function testOnlyAdminSetsSourcesAndEmergencyRoleRemovesThem() public {
        vm.expectRevert();
        vm.prank(stranger);
        oracle.setSource(address(weth), IPriceFeed(address(feed)), 1 days);

        vm.prank(admin);
        oracle.setSource(address(weth), IPriceFeed(address(feed)), 1 days);
        assertEq(oracle.getPrice(address(weth)), 1_234_567_890_000_000_000);

        vm.expectRevert();
        vm.prank(stranger);
        oracle.removeSource(address(weth));

        vm.prank(emergencyAdmin);
        oracle.removeSource(address(weth));
        vm.expectRevert(abi.encodeWithSelector(NoPriceSource.selector, address(weth)));
        oracle.getPrice(address(weth));
    }
}
