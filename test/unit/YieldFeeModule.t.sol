// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FeeActions} from "../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {Test} from "forge-std/Test.sol";

contract YieldFeeReleaseHarness is YieldSeekerYieldFeeModule {
    constructor() YieldSeekerYieldFeeModule(YieldSeekerFeeTracker(address(1)), 5_000) {}

    function setBasis(address wallet, address target, uint256 basis) external {
        costBasis[wallet][target] = basis;
    }

    function release(address wallet, FeeActions.Withdraw calldata withdrawal) external returns (uint256) {
        return _releaseCostBasis(wallet, withdrawal);
    }
}

contract YieldFeeModuleTest is Test {
    address private constant WALLET = address(0xA11CE);
    address private constant TARGET = address(0xBEEF);

    YieldFeeReleaseHarness private module;

    function setUp() public {
        module = new YieldFeeReleaseHarness();
    }

    function testZeroSpentWithdrawalTreatsAllAssetsOutAsYield() public {
        module.setBasis(WALLET, TARGET, 100);
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: TARGET, spent: 0, heldBefore: 100, assetsOut: 50});

        assertEq(module.release(WALLET, withdrawal), 50);
        assertEq(module.costBasis(WALLET, TARGET), 100);
    }

    function testZeroHeldWithdrawalTreatsAllAssetsOutAsYield() public {
        module.setBasis(WALLET, TARGET, 100);
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: TARGET, spent: 100, heldBefore: 0, assetsOut: 50});

        assertEq(module.release(WALLET, withdrawal), 50);
        assertEq(module.costBasis(WALLET, TARGET), 100);
    }

    function testPartialProfitThenLossReleasesCostBasisProportionally() public {
        module.setBasis(WALLET, TARGET, 1_000);
        FeeActions.Withdraw memory partialProfit = FeeActions.Withdraw({target: TARGET, spent: 500, heldBefore: 1_000, assetsOut: 550});
        assertEq(module.release(WALLET, partialProfit), 50);
        assertEq(module.costBasis(WALLET, TARGET), 500);

        FeeActions.Withdraw memory finalLoss = FeeActions.Withdraw({target: TARGET, spent: 500, heldBefore: 500, assetsOut: 450});
        assertEq(module.release(WALLET, finalLoss), 0);
        assertEq(module.costBasis(WALLET, TARGET), 0);
    }

    function testLargePositionWithdrawalCalculatesProfitWithoutOverflow() public {
        uint256 assetsDeposited = type(uint128).max;
        uint256 growth = 1_000e6;
        module.setBasis(WALLET, TARGET, assetsDeposited);
        FeeActions.Withdraw memory withdrawal = FeeActions.Withdraw({target: TARGET, spent: assetsDeposited, heldBefore: assetsDeposited, assetsOut: assetsDeposited + growth});

        assertEq(module.release(WALLET, withdrawal), growth);
        assertEq(module.costBasis(WALLET, TARGET), 0);
    }
}
