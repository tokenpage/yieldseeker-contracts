// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../../src/adapters/AaveV3LendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerYieldFeeModule} from "../../../src/fees/YieldFeeModule.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract FeeAccountingHandler is IntegrationBase {
    bytes32 private constant YIELD_RECORDED = keccak256("YieldRecorded(address,uint256,uint256)");
    bytes32 private constant BORROW_FEE_CHARGED = keccak256("BorrowFeeCharged(address,address,address,uint256,uint256)");
    bytes32 private constant FEE_PAID = keccak256("FeePaid(address,uint256)");
    uint256 private constant USDC_UNIT = 1e6;

    address[2] private vaultOwners;
    address[2] private borrowOwners;
    AgentWallet[2] private vaultWallets;
    AgentWallet[2] private borrowWallets;
    mapping(address wallet => uint256 amount) private _claimedRewards;

    mapping(address wallet => uint256 amount) public vaultYieldCharged;
    mapping(address wallet => uint256 amount) public vaultYieldPaid;
    mapping(address wallet => uint256 amount) public borrowYieldCharged;
    mapping(address wallet => uint256 amount) public borrowYieldPaid;
    mapping(address wallet => uint256 amount) public borrowFeeCharged;
    mapping(address wallet => uint256 amount) public borrowFeePaid;
    uint256 public collectorBalanceAtStart;

    uint256 public vaultDepositCalls;
    uint256 public vaultPartialWithdrawalCalls;
    uint256 public vaultFullWithdrawalCalls;
    uint256 public vaultGainCalls;
    uint256 public vaultLossCalls;
    uint256 public rewardClaimAndSaleCalls;
    uint256 public collateralSupplyCalls;
    uint256 public borrowCalls;
    uint256 public repayCalls;
    uint256 public collateralWithdrawalCalls;
    uint256 public timeAdvanceCalls;
    uint256 public priceMoveCalls;
    uint256 public ownerBaseWithdrawalCalls;
    uint256 public ownerBorrowedTokenWithdrawalCalls;
    uint256 public operatorCheckpointCalls;

    function setUp() public override {
        super.setUp();
        vaultOwners[0] = makeAddr("vault owner one");
        vaultOwners[1] = makeAddr("vault owner two");
        borrowOwners[0] = makeAddr("borrow owner one");
        borrowOwners[1] = makeAddr("borrow owner two");
        vaultWallets[0] = _createVaultWallet(vaultOwners[0], 0);
        vaultWallets[1] = _createVaultWallet(vaultOwners[1], 0);
        borrowWallets[0] = _createBorrowWallet(borrowOwners[0], 0);
        borrowWallets[1] = _createBorrowWallet(borrowOwners[1], 0);
        collectorBalanceAtStart = usdc.balanceOf(feeCollector);
    }

    function vaultUserDeposits(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _vaultWallet(ownerSeed);
        uint256 amount = bound(amountSeed, USDC_UNIT, 10 * USDC_UNIT);
        _depositVault(wallet, amount);
    }

    function vaultUserWithdrawsPartOfTheirPosition(uint256 ownerSeed, uint256 sharesSeed) external {
        AgentWallet wallet = _vaultWallet(ownerSeed);
        _ensureVaultPosition(wallet);
        uint256 shares = erc4626Vault.balanceOf(address(wallet));
        if (shares < 2) {
            _depositVault(wallet, 2 * USDC_UNIT);
            shares = erc4626Vault.balanceOf(address(wallet));
        }
        uint256 partialShares = bound(sharesSeed, 1, shares - 1);
        if (erc4626Vault.convertToAssets(partialShares) == 0) partialShares = shares - 1;
        if (erc4626Vault.convertToAssets(partialShares) == 0) {
            _depositVault(wallet, 2 * USDC_UNIT);
            shares = erc4626Vault.balanceOf(address(wallet));
            partialShares = shares / 2;
        }
        vm.recordLogs();
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, partialShares));
        _captureFeeEvents();
        vaultPartialWithdrawalCalls++;
    }

    function vaultUserWithdrawsTheirFullPosition(uint256 ownerSeed) external {
        AgentWallet wallet = _vaultWallet(ownerSeed);
        _ensureVaultPosition(wallet);
        uint256 shares = erc4626Vault.balanceOf(address(wallet));
        if (erc4626Vault.convertToAssets(shares) == 0) {
            _depositVault(wallet, 2 * USDC_UNIT);
            shares = erc4626Vault.balanceOf(address(wallet));
        }
        vm.recordLogs();
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, shares));
        _captureFeeEvents();
        vaultFullWithdrawalCalls++;
    }

    function vaultGainsValue(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 10 * USDC_UNIT);
        usdc.mint(address(erc4626Vault), amount);
        vaultGainCalls++;
    }

    function vaultLosesValue(uint256 ownerSeed, uint256 lossSeed) external {
        AgentWallet wallet = _vaultWallet(ownerSeed);
        _ensureVaultPosition(wallet);
        uint256 availableLoss = usdc.balanceOf(address(erc4626Vault)) / 2;
        if (availableLoss != 0) {
            uint256 maximumLoss = availableLoss < 10 * USDC_UNIT ? availableLoss : 10 * USDC_UNIT;
            uint256 loss = bound(lossSeed, 1, maximumLoss);
            usdc.burn(address(erc4626Vault), loss);
        }
        vaultLossCalls++;
    }

    function userClaimsAndSellsRewards(uint256 ownerSeed, uint256 rewardSeed) external {
        AgentWallet wallet = _vaultWallet(ownerSeed);
        uint256 rewardAmount = _claimedRewards[address(wallet)] + bound(rewardSeed, 1e15, 1e18);
        _claimedRewards[address(wallet)] = rewardAmount;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = rewardAmount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        vm.recordLogs();
        _execute(wallet, address(merklAdapter), address(merklDistributor), abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
        _captureFeeEvents();

        uint256 rewardBalance = rewardToken.balanceOf(address(wallet));
        address[] memory path = new address[](2);
        path[0] = address(rewardToken);
        path[1] = address(usdc);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3_000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        uniswapV3Router.setBuyAmount(USDC_UNIT);
        vm.recordLogs();
        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeWithSelector(uniswapV3SwapAdapter.swap.selector, address(rewardToken), address(usdc), route, rewardBalance, USDC_UNIT, block.timestamp));
        _captureFeeEvents();
        rewardClaimAndSaleCalls++;
    }

    function borrowUserSuppliesCollateral(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        uint256 amount = bound(amountSeed, USDC_UNIT, 10 * USDC_UNIT);
        _supplyAaveV3Collateral(wallet, amount);
        _supplyAaveV4Collateral(wallet, amount);
    }

    function borrowUserBorrowsTokens(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        _ensureCollateral(wallet);
        uint256 amount = bound(amountSeed, 1e15, 1e16);
        _borrowBothMarkets(wallet, amount);
    }

    function borrowUserRepaysDebt(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        uint256 totalDebt = aaveV3VariableDebtToken.balanceOf(address(wallet)) + aaveV4Spoke.getUserTotalDebt(2, address(wallet));
        uint256 tokenBalance = weth.balanceOf(address(wallet));
        if (totalDebt == 0 || tokenBalance == 0) {
            _ensureCollateral(wallet);
            _borrowBothMarkets(wallet, 1e15);
            tokenBalance = weth.balanceOf(address(wallet));
        }
        uint256 debtV3 = aaveV3VariableDebtToken.balanceOf(address(wallet));
        uint256 repayV3 = debtV3 < tokenBalance ? debtV3 : tokenBalance;
        if (repayV3 != 0) {
            uint256 amountV3 = bound(amountSeed, 1, repayV3);
            vm.recordLogs();
            _executeAaveV3(wallet, aaveV3LendingAdapter.repay.selector, amountV3);
            _captureFeeEvents();
            repayCalls++;
            tokenBalance -= amountV3;
        }
        uint256 debtV4 = aaveV4Spoke.getUserTotalDebt(2, address(wallet));
        uint256 repayV4 = debtV4 < tokenBalance ? debtV4 : tokenBalance;
        if (repayV4 != 0) {
            uint256 amountV4 = bound(amountSeed, 1, repayV4);
            vm.recordLogs();
            _executeAaveV4(wallet, aaveV4LendingAdapter.repay.selector, amountV4);
            _captureFeeEvents();
            repayCalls++;
        }
    }

    function borrowUserWithdrawsCollateral(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        _ensureCollateral(wallet);
        uint256 collateralV3 = aaveV3CollateralAToken.balanceOf(address(wallet));
        uint256 amountV3 = bound(amountSeed, 1, collateralV3);
        vm.recordLogs();
        _executeAaveV3(wallet, aaveV3LendingAdapter.withdrawCollateral.selector, amountV3);
        _captureFeeEvents();
        collateralWithdrawalCalls++;

        uint256 collateralV4 = aaveV4Spoke.getUserSuppliedAssets(1, address(wallet));
        uint256 amountV4 = bound(amountSeed, 1, collateralV4);
        vm.recordLogs();
        _executeAaveV4(wallet, aaveV4LendingAdapter.withdrawCollateral.selector, amountV4);
        _captureFeeEvents();
        collateralWithdrawalCalls++;
    }

    function timePasses(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 30 days));
        timeAdvanceCalls++;
    }

    function debtTokenPriceMoves(uint256 priceSeed) external {
        uint256 price = bound(priceSeed, 100e8, 3_000e8);
        aaveV3LendingPool.setAssetPrice(address(weth), price);
        aaveV4Spoke.setReservePrice(2, price);
        priceMoveCalls++;
    }

    function ownerWithdrawsBaseAsset(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        uint256 owed = borrowFeeTracker.feesOwedInBaseAsset(address(wallet));
        uint256 balance = usdc.balanceOf(address(wallet));
        if (balance <= owed) _fundWallet(wallet, address(usdc), owed - balance + USDC_UNIT);
        uint256 available = wallet.withdrawableBalance(address(usdc));
        uint256 amount = bound(amountSeed, 1, available);
        address walletOwner = wallet.owner();
        vm.recordLogs();
        vm.prank(walletOwner);
        wallet.withdrawAssetToUser(walletOwner, address(usdc), amount);
        _captureFeeEvents();
        ownerBaseWithdrawalCalls++;
    }

    function ownerWithdrawsBorrowedTokens(uint256 ownerSeed, uint256 amountSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        if (weth.balanceOf(address(wallet)) == 0) {
            _ensureCollateral(wallet);
            _borrowBothMarkets(wallet, 1e15);
        }
        uint256 balance = weth.balanceOf(address(wallet));
        uint256 amount = bound(amountSeed, 1, balance);
        address walletOwner = wallet.owner();
        vm.recordLogs();
        vm.prank(walletOwner);
        wallet.withdrawAssetToUser(walletOwner, address(weth), amount);
        _captureFeeEvents();
        ownerBorrowedTokenWithdrawalCalls++;
    }

    function operatorCheckpointsTheMarket(uint256 ownerSeed) external {
        AgentWallet wallet = _borrowWallet(ownerSeed);
        uint256 debt = aaveV3VariableDebtToken.balanceOf(address(wallet)) + aaveV4Spoke.getUserTotalDebt(2, address(wallet));
        if (debt == 0) {
            _ensureCollateral(wallet);
            _borrowBothMarkets(wallet, 1e15);
        }
        address targetV3 = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        vm.recordLogs();
        _execute(wallet, address(aaveV3LendingAdapter), targetV3, abi.encodeWithSelector(aaveV3LendingAdapter.checkpoint.selector, aaveV3Market));
        _captureFeeEvents();
        address targetV4 = aaveV4LendingAdapter.marketTarget(aaveV4Market);
        vm.recordLogs();
        _execute(wallet, address(aaveV4LendingAdapter), targetV4, abi.encodeWithSelector(aaveV4LendingAdapter.checkpoint.selector, aaveV4Market));
        _captureFeeEvents();
        operatorCheckpointCalls++;
    }

    function totalGhostFeesPaid() public view returns (uint256 total) {
        for (uint256 i; i < 2; i++) {
            address vaultWallet = address(vaultWallets[i]);
            address borrowWallet = address(borrowWallets[i]);
            total += vaultYieldPaid[vaultWallet];
            total += borrowYieldPaid[borrowWallet];
            total += borrowFeePaid[borrowWallet];
        }
    }

    function assertFeeAccounting() external view {
        for (uint256 i; i < 2; i++) {
            address vaultWallet = address(vaultWallets[i]);
            uint256 vaultOwed = vaultYieldFeeModule.feesOwed(vaultWallet);
            assertEq(vaultYieldCharged[vaultWallet], vaultOwed + vaultYieldPaid[vaultWallet]);
            assertLe(vaultOwed, vaultYieldCharged[vaultWallet]);

            address borrowWallet = address(borrowWallets[i]);
            uint256 yieldOwed = borrowYieldFeeModule.feesOwed(borrowWallet);
            assertEq(borrowYieldCharged[borrowWallet], yieldOwed + borrowYieldPaid[borrowWallet]);
            assertLe(yieldOwed, borrowYieldCharged[borrowWallet]);
            uint256 borrowOwed = borrowFeeModule.feesOwed(borrowWallet);
            assertEq(borrowFeeCharged[borrowWallet], borrowOwed + borrowFeePaid[borrowWallet]);
            assertLe(borrowOwed, borrowFeeCharged[borrowWallet]);
        }
    }

    function assertTokenDebtMatchesPositions() external view {
        for (uint256 i; i < 2; i++) {
            AgentWallet wallet = borrowWallets[i];
            address positionV3 = aaveV3LendingAdapter.debtPosition(aaveV3Market);
            address positionV4 = aaveV4LendingAdapter.debtPosition(aaveV4Market);
            (uint128 debtV3,,) = borrowFeeModule.debtPositions(address(wallet), positionV3);
            (uint128 debtV4,,) = borrowFeeModule.debtPositions(address(wallet), positionV4);
            assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), uint256(debtV3) + debtV4);
        }
    }

    function assertAllWorkflowCalls() external view {
        assertGt(vaultDepositCalls, 0);
        assertGt(vaultPartialWithdrawalCalls, 0);
        assertGt(vaultFullWithdrawalCalls, 0);
        assertGt(vaultGainCalls, 0);
        assertGt(vaultLossCalls, 0);
        assertGt(rewardClaimAndSaleCalls, 0);
        assertGt(collateralSupplyCalls, 0);
        assertGt(borrowCalls, 0);
        assertGt(repayCalls, 0);
        assertGt(collateralWithdrawalCalls, 0);
        assertGt(timeAdvanceCalls, 0);
        assertGt(priceMoveCalls, 0);
        assertGt(ownerBaseWithdrawalCalls, 0);
        assertGt(ownerBorrowedTokenWithdrawalCalls, 0);
        assertGt(operatorCheckpointCalls, 0);
    }

    function _depositVault(AgentWallet wallet, uint256 amount) private {
        uint256 totalShares = erc4626Vault.totalSupply();
        if (totalShares != 0) {
            uint256 vaultAssets = usdc.balanceOf(address(erc4626Vault));
            if (vaultAssets == 0) {
                usdc.mint(address(erc4626Vault), 1);
                vaultAssets = 1;
            }
            uint256 minAssetsForOneShare = vaultAssets / totalShares;
            if (vaultAssets % totalShares != 0) minAssetsForOneShare++;
            if (amount < minAssetsForOneShare) amount = minAssetsForOneShare;
        }
        uint256 requiredBalance = amount + vaultFeeTracker.feesOwedInBaseAsset(address(wallet));
        uint256 balance = usdc.balanceOf(address(wallet));
        if (balance < requiredBalance) _fundWallet(wallet, address(usdc), requiredBalance - balance);
        vm.recordLogs();
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, amount));
        _captureFeeEvents();
        vaultDepositCalls++;
    }

    function _ensureVaultPosition(AgentWallet wallet) private {
        uint256 shares = erc4626Vault.balanceOf(address(wallet));
        if (shares == 0 || erc4626Vault.convertToAssets(shares) == 0) {
            if (erc4626Vault.totalSupply() != 0 && usdc.balanceOf(address(erc4626Vault)) == 0) usdc.mint(address(erc4626Vault), 1);
            _depositVault(wallet, 2 * USDC_UNIT);
        }
    }

    function _supplyAaveV3Collateral(AgentWallet wallet, uint256 amount) private {
        _fundForCollateralSupply(wallet, amount);
        vm.recordLogs();
        _executeAaveV3(wallet, aaveV3LendingAdapter.supplyCollateral.selector, amount);
        _captureFeeEvents();
        collateralSupplyCalls++;
    }

    function _supplyAaveV4Collateral(AgentWallet wallet, uint256 amount) private {
        _fundForCollateralSupply(wallet, amount);
        vm.recordLogs();
        _executeAaveV4(wallet, aaveV4LendingAdapter.supplyCollateral.selector, amount);
        _captureFeeEvents();
        collateralSupplyCalls++;
    }

    function _ensureCollateral(AgentWallet wallet) private {
        if (aaveV3CollateralAToken.balanceOf(address(wallet)) == 0) _supplyAaveV3Collateral(wallet, USDC_UNIT);
        if (aaveV4Spoke.getUserSuppliedAssets(1, address(wallet)) == 0) _supplyAaveV4Collateral(wallet, USDC_UNIT);
    }

    function _fundForCollateralSupply(AgentWallet wallet, uint256 amount) private {
        uint256 requiredBalance = amount + borrowFeeTracker.feesOwedInBaseAsset(address(wallet));
        uint256 balance = usdc.balanceOf(address(wallet));
        if (balance < requiredBalance) _fundWallet(wallet, address(usdc), requiredBalance - balance);
    }

    function _borrowBothMarkets(AgentWallet wallet, uint256 amount) private {
        vm.recordLogs();
        _executeAaveV3(wallet, aaveV3LendingAdapter.borrow.selector, amount);
        _captureFeeEvents();
        vm.recordLogs();
        _executeAaveV4(wallet, aaveV4LendingAdapter.borrow.selector, amount);
        _captureFeeEvents();
        borrowCalls++;
    }

    function _executeAaveV3(AgentWallet wallet, bytes4 selector, uint256 amount) private {
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeWithSelector(selector, aaveV3Market, amount));
    }

    function _executeAaveV4(AgentWallet wallet, bytes4 selector, uint256 amount) private {
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeWithSelector(selector, aaveV4Market, amount));
    }

    function _vaultWallet(uint256 seed) private view returns (AgentWallet) {
        return vaultWallets[seed % 2];
    }

    function _borrowWallet(uint256 seed) private view returns (AgentWallet) {
        return borrowWallets[seed % 2];
    }

    function _captureFeeEvents() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length < 2) continue;
            address wallet = address(uint160(uint256(entry.topics[1])));
            if (entry.emitter == address(vaultYieldFeeModule)) {
                if (entry.topics[0] == YIELD_RECORDED) {
                    (, uint256 fee) = abi.decode(entry.data, (uint256, uint256));
                    vaultYieldCharged[wallet] += fee;
                } else if (entry.topics[0] == FEE_PAID) {
                    uint256 amount = abi.decode(entry.data, (uint256));
                    vaultYieldPaid[wallet] += amount;
                }
            } else if (entry.emitter == address(borrowYieldFeeModule)) {
                if (entry.topics[0] == YIELD_RECORDED) {
                    (, uint256 fee) = abi.decode(entry.data, (uint256, uint256));
                    borrowYieldCharged[wallet] += fee;
                } else if (entry.topics[0] == FEE_PAID) {
                    uint256 amount = abi.decode(entry.data, (uint256));
                    borrowYieldPaid[wallet] += amount;
                }
            } else if (entry.emitter == address(borrowFeeModule)) {
                if (entry.topics[0] == BORROW_FEE_CHARGED) {
                    (, uint256 feeInBaseAsset) = abi.decode(entry.data, (uint256, uint256));
                    borrowFeeCharged[wallet] += feeInBaseAsset;
                } else if (entry.topics[0] == FEE_PAID) {
                    uint256 amount = abi.decode(entry.data, (uint256));
                    borrowFeePaid[wallet] += amount;
                }
            }
        }
    }
}

contract FeeAccountingInvariantTest is StdInvariant, Test {
    FeeAccountingHandler private handler;

    function setUp() public {
        handler = new FeeAccountingHandler();
        handler.setUp();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = FeeAccountingHandler.vaultUserDeposits.selector;
        selectors[1] = FeeAccountingHandler.vaultUserWithdrawsPartOfTheirPosition.selector;
        selectors[2] = FeeAccountingHandler.vaultUserWithdrawsTheirFullPosition.selector;
        selectors[3] = FeeAccountingHandler.vaultGainsValue.selector;
        selectors[4] = FeeAccountingHandler.vaultLosesValue.selector;
        selectors[5] = FeeAccountingHandler.userClaimsAndSellsRewards.selector;
        selectors[6] = FeeAccountingHandler.borrowUserSuppliesCollateral.selector;
        selectors[7] = FeeAccountingHandler.borrowUserBorrowsTokens.selector;
        selectors[8] = FeeAccountingHandler.borrowUserRepaysDebt.selector;
        selectors[9] = FeeAccountingHandler.borrowUserWithdrawsCollateral.selector;
        selectors[10] = FeeAccountingHandler.timePasses.selector;
        selectors[11] = FeeAccountingHandler.debtTokenPriceMoves.selector;
        selectors[12] = FeeAccountingHandler.ownerWithdrawsBaseAsset.selector;
        selectors[13] = FeeAccountingHandler.ownerWithdrawsBorrowedTokens.selector;
        selectors[14] = FeeAccountingHandler.operatorCheckpointsTheMarket.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows() public view {
        handler.assertFeeAccounting();
        handler.assertTokenDebtMatchesPositions();
        assertEq(handler.usdc().balanceOf(handler.feeCollector()), handler.collectorBalanceAtStart() + handler.totalGhostFeesPaid());
    }

    function test_everyFeeWorkflowOnceLeavesLedgersAndCollectorInAgreement() public {
        handler.vaultUserDeposits(0, 2 * 1e6);
        handler.vaultUserWithdrawsPartOfTheirPosition(0, 1);
        handler.vaultUserWithdrawsTheirFullPosition(0);
        handler.vaultGainsValue(1);
        handler.vaultLosesValue(0, 1);
        handler.userClaimsAndSellsRewards(0, 1e18);

        handler.borrowUserSuppliesCollateral(0, 2 * 1e6);
        handler.borrowUserBorrowsTokens(0, 1e15);
        handler.timePasses(1);
        handler.debtTokenPriceMoves(2_000e8);
        handler.operatorCheckpointsTheMarket(0);
        handler.borrowUserRepaysDebt(0, type(uint256).max);
        handler.borrowUserWithdrawsCollateral(0, type(uint256).max);
        handler.ownerWithdrawsBorrowedTokens(0, type(uint256).max);
        handler.ownerWithdrawsBaseAsset(0, type(uint256).max);

        handler.assertAllWorkflowCalls();
        handler.assertFeeAccounting();
        handler.assertTokenDebtMatchesPositions();
        assertEq(handler.usdc().balanceOf(handler.feeCollector()), handler.collectorBalanceAtStart() + handler.totalGhostFeesPaid());
    }
}
