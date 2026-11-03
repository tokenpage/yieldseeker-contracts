// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowFeeModuleTest is Test {
    uint256 private constant YEAR = 365 days;
    address private constant MARKET = address(uint160(uint256(keccak256("market"))));

    address private admin = makeAddr("admin");
    address private collector = makeAddr("collector");
    address private owner = makeAddr("owner");

    MockERC20WithDecimals private baseAsset;
    MockERC20WithDecimals private debtToken;
    MockFeeWallet private wallet;
    YieldSeekerFeeTracker private tracker;
    YieldSeekerBorrowFeeModule private module;

    function setUp() public {
        baseAsset = new MockERC20WithDecimals("Base", "BASE", 18);
        debtToken = new MockERC20WithDecimals("Debt", "DEBT", 6);
        wallet = new MockFeeWallet(owner, baseAsset);
        tracker = new YieldSeekerFeeTracker(admin, collector);
        module = new YieldSeekerBorrowFeeModule(tracker, 1_000);
        vm.startPrank(admin);
        tracker.setFeeModule(BORROW_FEE, module);
        tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 1_000})));
        tracker.setWalletFactory(address(this));
        vm.stopPrank();
    }

    function testOnActionRejectsNonTrackerCaller() public {
        address attacker = makeAddr("attacker");
        bytes memory data = abi.encode(FeeActions.DebtChange({market: MARKET, debtToken: address(debtToken), debtBefore: 0, borrowed: 1, repaid: 0, debtPriceInBaseAsset: 0}));
        bytes memory unauthorizedError = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, attacker);

        vm.expectRevert(unauthorizedError);
        vm.prank(attacker);
        module.onAction(address(wallet), FeeActions.DEBT_CHANGE, data, 0);
    }

    function testEachPeriodIsChargedOnTheDebtAtItsStart() public {
        _reportDebt(0, 1_000);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _reportDebt(600, 0);

        assertEq(module.feesOwed(address(wallet)), 100);

        _reportDebt(1_200, 0);
        vm.warp(start + 2 * YEAR);
        assertEq(module.pendingFee(address(wallet), MARKET), 120);
        assertEq(module.feesOwed(address(wallet)), 100);
    }

    function _reportDebt(uint256 debtBefore, uint256 borrowed) private {
        bytes memory data = abi.encode(FeeActions.DebtChange({market: MARKET, debtToken: address(debtToken), debtBefore: debtBefore, borrowed: borrowed, repaid: 0, debtPriceInBaseAsset: debtBefore == 0 ? 0 : 1e36}));
        vm.prank(address(tracker));
        module.onAction(address(wallet), FeeActions.DEBT_CHANGE, data, 0);
    }
}
