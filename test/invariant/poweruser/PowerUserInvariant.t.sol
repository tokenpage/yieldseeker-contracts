// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {AWKAerodromeCLSwapAdapter} from "../../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {IMorphoBlue} from "../../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice} from "../../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../../src/fees/YieldFeeModule.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockCToken} from "../../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../../mocks/MockCompoundV3.sol";
import {MockLendingAaveV3Pool} from "../../mocks/MockLendingMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

contract PowerUserDualRewards {
    IERC20 private immutable WELL;
    IERC20 private immutable BASE;
    uint256 private immutable WELL_AMOUNT;
    uint256 private immutable BASE_AMOUNT;

    constructor(IERC20 well_, IERC20 base_, uint256 wellAmount_, uint256 baseAmount_) {
        WELL = well_;
        BASE = base_;
        WELL_AMOUNT = wellAmount_;
        BASE_AMOUNT = baseAmount_;
    }

    function claimReward(address holder, address[] calldata) external {
        require(WELL.transfer(holder, WELL_AMOUNT));
        require(BASE.transfer(holder, BASE_AMOUNT));
    }
}

struct PowerUserHandlerSetup {
    IntegrationBase system;
    address ownerA;
    address ownerB;
    address operator;
    AgentWallet vaultA;
    AgentWallet vaultB;
    AgentWallet borrowA;
    AgentWallet borrowB;
    PowerUserDualRewards dualRewards;
}

contract PowerUserHandler is Test {
    bytes32 private constant YIELD_RECORDED = keccak256("YieldRecorded(address,uint256,uint256)");
    bytes32 private constant BORROW_FEE_CHARGED = keccak256("BorrowFeeCharged(address,address,address,uint256,uint256)");
    bytes32 private constant FEE_PAID = keccak256("FeePaid(address,uint256)");
    uint256 private constant YEAR = 365 days;
    uint256 private constant USDC_UNIT = 1e6;
    address private constant LOSS_SINK = address(0xdead);

    IntegrationBase private immutable SYSTEM;
    PowerUserDualRewards private immutable dualRewards;
    address[2] private owners;
    AgentWallet[2] private vaultWallets;
    AgentWallet[2] private borrowWallets;
    address private immutable operator;

    uint256 public immutable initialOwnerValue;
    uint256 public immutable collectorBalanceAtStart;
    uint256 public authorizedGains;
    uint256 public allowedLosses;
    uint256 public roundingAllowance;
    uint256 public totalFeesPaid;
    uint256 public wethCapitalMinted;

    mapping(address wallet => uint256 amount) public yieldCharged;
    mapping(address wallet => uint256 amount) public yieldPaid;
    mapping(address wallet => uint256 amount) public borrowFeeCharged;
    mapping(address wallet => uint256 amount) public borrowFeePaid;
    mapping(address wallet => uint256 amount) public expectedBorrowFees;
    mapping(address wallet => uint256 amount) public realizedYield;
    mapping(address wallet => uint256 amount) public yieldActions;
    mapping(address wallet => mapping(address target => uint256 amount)) public basisGhost;
    mapping(address wallet => mapping(address position => uint256 debt)) public reportedDebt;
    mapping(address wallet => mapping(address position => uint256 time)) public reportedAt;
    mapping(address wallet => mapping(address position => uint256 price)) public reportedPrice;
    mapping(address wallet => mapping(address position => uint256 debt)) public unreportedDebt;
    mapping(address wallet => mapping(address token => uint256 amount)) private merklClaimable;

    uint256[4] public vaultDepositCalls;
    uint256[4] public vaultWithdrawalCalls;
    uint256[4] public vaultGainCalls;
    uint256[4] public vaultLossCalls;
    uint256[3] public lendingSupplyCalls;
    uint256[3] public lendingBorrowCalls;
    uint256[3] public lendingRepayCalls;
    uint256[3] public lendingWithdrawalCalls;
    uint256[3] public lendingCheckpointCalls;
    uint256 public lendingCollateralYieldCalls;
    uint256 public interestAccrualCalls;
    uint256 public merklCalls;
    uint256 public moonwellCalls;
    uint256[3] public rewardSaleCalls;
    uint256[3] public borrowSwapCalls;
    uint256 public transferCalls;
    uint256 public singleWithdrawalCalls;
    uint256 public allWithdrawalCalls;
    uint256 public batchWithdrawalCalls;
    uint256 public ethWithdrawalCalls;
    uint256 public ownerBlockCalls;
    uint256 public registrySyncCalls;
    uint256 public timeAdvanceCalls;
    uint256 public priceMoveCalls;
    uint256 public ownerDonationCalls;

    constructor(PowerUserHandlerSetup memory setup) {
        SYSTEM = setup.system;
        dualRewards = setup.dualRewards;
        owners[0] = setup.ownerA;
        owners[1] = setup.ownerB;
        operator = setup.operator;
        vaultWallets[0] = setup.vaultA;
        vaultWallets[1] = setup.vaultB;
        borrowWallets[0] = setup.borrowA;
        borrowWallets[1] = setup.borrowB;
        initialOwnerValue = totalOwnerValue();
        collectorBalanceAtStart = SYSTEM.usdc().balanceOf(SYSTEM.feeCollector());
    }

    function operatorDepositsVault(uint8 ownerSeed, uint8 adapterSeed, uint96 amountSeed, bool percentage) public {
        uint8 ownerIndex = ownerSeed % 2;
        uint8 adapterIndex = adapterSeed % 4;
        AgentWallet wallet = vaultWallets[ownerIndex];
        address adapter = _vaultAdapter(adapterIndex);
        address target = _vaultTarget(adapterIndex);
        _prepareExecution(wallet, adapter, target);
        uint256 amount = bound(uint256(amountSeed), USDC_UNIT, 100e6);
        if (percentage) {
            _ensureWalletBase(wallet, 2 * USDC_UNIT);
            vm.recordLogs();
            vm.prank(operator);
            bytes memory result = wallet.executeViaAdapter(adapter, target, abi.encodeWithSignature("depositPercentage(uint256)", 5_000));
            _captureFees();
            (, uint256 assetsIn) = abi.decode(abi.decode(result, (bytes)), (uint256, uint256));
            basisGhost[address(wallet)][target] += assetsIn;
        } else {
            _ensureWalletBase(wallet, amount);
            vm.recordLogs();
            vm.prank(operator);
            bytes memory result = wallet.executeViaAdapter(adapter, target, abi.encodeWithSignature("deposit(uint256)", amount));
            _captureFees();
            (, uint256 assetsIn) = abi.decode(abi.decode(result, (bytes)), (uint256, uint256));
            basisGhost[address(wallet)][target] += assetsIn;
        }
        vaultDepositCalls[adapterIndex]++;
        roundingAllowance++;
    }

    function operatorWithdrawsVault(uint8 ownerSeed, uint8 adapterSeed, bool withdrawAll) public {
        uint8 adapterIndex = adapterSeed % 4;
        AgentWallet wallet = vaultWallets[ownerSeed % 2];
        address adapter = _vaultAdapter(adapterIndex);
        address target = _vaultTarget(adapterIndex);
        _prepareExecution(wallet, adapter, target);
        uint256 held = _vaultPosition(wallet, adapterIndex);
        if (held == 0) return;
        uint256 amount = withdrawAll ? held : held / 2;
        if (amount == 0) amount = held;
        uint256 heldBefore = held;
        vm.recordLogs();
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(adapter, target, abi.encodeWithSignature("withdraw(uint256)", amount));
        _captureFees();
        uint256 assetsOut = abi.decode(abi.decode(result, (bytes)), (uint256));
        uint256 spent = heldBefore - _vaultPosition(wallet, adapterIndex);
        _updateBasisAfterWithdrawal(wallet, target, heldBefore, spent, assetsOut);
        vaultWithdrawalCalls[adapterIndex]++;
    }

    function operatorChangesVaultValue(uint8 ownerSeed, uint8 adapterSeed, uint96 amountSeed, uint8 modeSeed) public {
        uint8 ownerIndex = ownerSeed % 2;
        uint8 adapterIndex = adapterSeed % 4;
        AgentWallet wallet = vaultWallets[ownerIndex];
        uint256 amount = bound(uint256(amountSeed), 1e6, 100e6);
        uint8 mode = modeSeed % 3;
        if (mode == 1) {
            uint256 loss = _applyVaultLoss(wallet, adapterIndex, amount);
            if (loss > 0) {
                allowedLosses += loss;
                vaultLossCalls[adapterIndex]++;
            }
            return;
        }

        uint256 portfolioBefore = _allVaultPositionValue();
        if (adapterIndex == 0) {
            SYSTEM.usdc().mint(address(SYSTEM.erc4626Vault()), amount);
        } else if (adapterIndex == 1) {
            SYSTEM.aaveV3Vault().addYield(address(wallet), amount);
            SYSTEM.usdc().mint(address(SYSTEM.aaveV3Vault()), amount);
        } else if (adapterIndex == 2) {
            MockCToken market = SYSTEM.compoundV2Vault();
            uint256 poolValueBefore = Math.mulDiv(market.totalSupply(), market.exchangeRateCurrent(), 1e18);
            market.addYield(100);
            uint256 poolValueAfter = Math.mulDiv(market.totalSupply(), market.exchangeRateCurrent(), 1e18);
            uint256 gain = poolValueAfter - poolValueBefore;
            SYSTEM.usdc().mint(address(market), gain + 2);
        } else {
            SYSTEM.compoundV3Market().addYield(address(wallet), amount);
            SYSTEM.usdc().mint(address(SYSTEM.compoundV3Market()), amount);
        }
        uint256 portfolioAfter = _allVaultPositionValue();
        if (portfolioAfter > portfolioBefore) authorizedGains += portfolioAfter - portfolioBefore;
        vaultGainCalls[adapterIndex]++;
    }

    function ownerDonatesToVault(uint8 ownerSeed, uint96 amountSeed) public {
        AgentWallet wallet = vaultWallets[ownerSeed % 2];
        address owner = wallet.owner();
        IERC20 baseToken = SYSTEM.usdc();
        address vault = address(SYSTEM.erc4626Vault());
        if (SYSTEM.erc4626Vault().balanceOf(address(wallet)) == 0) {
            operatorDepositsVault(ownerSeed, 0, uint96(10 * USDC_UNIT), false);
        }
        uint256 amount = bound(uint256(amountSeed), 1e6, 10e6);
        _ensureOwnerUsdc(owner, amount);
        vm.prank(owner);
        baseToken.transfer(vault, amount);
        ownerDonationCalls++;
    }

    function operatorLendingWorkflow(uint8 ownerSeed, uint8 marketSeed, uint96 amountSeed, uint96 borrowSeed) public {
        uint8 marketIndex = marketSeed % 3;
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        uint256 collateral = bound(uint256(amountSeed), 10e6, 200e6);
        if (marketIndex == 0) {
            MockLendingAaveV3Pool pool = SYSTEM.aaveV3LendingPool();
            vm.prank(address(wallet));
            pool.setUserEMode(1);
        }
        _supplyCollateral(wallet, marketIndex, collateral);
        uint256 borrowed = bound(uint256(borrowSeed), 1e15, collateral * 1e8);
        _executeLending(wallet, marketIndex, _borrowCall(marketIndex, borrowed));
        lendingBorrowCalls[marketIndex]++;
        roundingAllowance++;
    }

    function operatorAccruesLendingCollateral(uint8 ownerSeed, uint8 marketSeed, uint96 amountSeed) public {
        uint8 marketIndex = marketSeed % 3;
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        uint256 collateral = _lendingCollateral(wallet, marketIndex);
        if (collateral == 0) _supplyCollateral(wallet, marketIndex, 100e6);
        uint256 amount = bound(uint256(amountSeed), 1e6, 50e6);
        if (marketIndex == 0) {
            SYSTEM.aaveV3LendingPool().accrueCollateral(address(SYSTEM.usdc()), address(wallet), amount);
        } else if (marketIndex == 1) {
            SYSTEM.aaveV4Spoke().accrueSuppliedAssets(1, address(wallet), amount);
        } else {
            (, IMorphoBlue.MarketParams memory params) = abi.decode(SYSTEM.morphoMarket(), (address, IMorphoBlue.MarketParams));
            SYSTEM.morpho().accrueCollateral(params, address(wallet), amount);
        }
        authorizedGains += amount;
        lendingCollateralYieldCalls++;
    }

    function operatorWithdrawsCollateral(uint8 ownerSeed, uint8 marketSeed, bool withdrawAll) public {
        uint8 marketIndex = marketSeed % 3;
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        uint256 heldBefore = _lendingCollateral(wallet, marketIndex);
        if (heldBefore == 0) {
            _supplyCollateral(wallet, marketIndex, 100e6);
            heldBefore = _lendingCollateral(wallet, marketIndex);
        }
        uint256 amount = withdrawAll ? type(uint256).max : heldBefore / 2;
        if (amount == 0) amount = heldBefore;
        address target = _marketTarget(marketIndex);
        address adapter = _lendingAdapter(marketIndex);
        _prepareExecution(wallet, adapter, target);
        bytes memory result = _executeLending(wallet, marketIndex, _withdrawCollateralCall(marketIndex, amount));
        uint256 assetsOut = abi.decode(abi.decode(result, (bytes)), (uint256));
        uint256 spent = heldBefore - _lendingCollateral(wallet, marketIndex);
        _updateBasisAfterWithdrawal(wallet, _collateralPosition(marketIndex), heldBefore, spent, assetsOut);
        lendingWithdrawalCalls[marketIndex]++;
    }

    function operatorRepaysMarket(uint8 ownerSeed, uint8 marketSeed, uint96 amountSeed, bool repayAll) public {
        uint8 marketIndex = marketSeed % 3;
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        _ensureMarketDebt(wallet, marketIndex);
        uint256 debt = _marketDebt(wallet, marketIndex);
        _ensureWalletWeth(wallet, debt);
        uint256 amount = repayAll ? type(uint256).max : bound(uint256(amountSeed), 1, debt);
        _executeLending(wallet, marketIndex, _repayCall(marketIndex, amount));
        roundingAllowance++;
    }

    function operatorCheckpointsMarket(uint8 ownerSeed, uint8 marketSeed) public {
        uint8 marketIndex = marketSeed % 3;
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        _ensureMarketDebt(wallet, marketIndex);
        _executeLending(wallet, marketIndex, _checkpointCall(marketIndex));
        lendingCheckpointCalls[marketIndex]++;
    }

    function protocolAccruesInterest(uint8 ownerSeed, uint96 amountSeed) public {
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        _ensureMarketDebt(wallet, 0);
        uint256 amount = bound(uint256(amountSeed), 1e12, 1e15);
        SYSTEM.aaveV3LendingPool().growDebt(address(SYSTEM.weth()), address(wallet), amount);
        unreportedDebt[address(wallet)][_debtPosition(0)] += amount;
        allowedLosses += _quoteWethToUsdc(amount);
        interestAccrualCalls++;
        roundingAllowance++;
    }

    function operatorClaimsMerklAndSells(uint8 ownerSeed, uint8 dexSeed, uint96 amountSeed) public {
        AgentWallet wallet = ownerSeed % 2 == 0 ? vaultWallets[0] : borrowWallets[1];
        address reward = address(SYSTEM.rewardToken());
        uint256 rewardIncrease = bound(uint256(amountSeed), 1e18, 5e18);
        uint256 baseIncrease = bound(uint256(amountSeed), 1e6, 5e6);
        merklClaimable[address(wallet)][reward] += rewardIncrease;
        merklClaimable[address(wallet)][address(SYSTEM.usdc())] += baseIncrease;
        SYSTEM.rewardToken().mint(address(SYSTEM.merklDistributor()), rewardIncrease);
        SYSTEM.usdc().mint(address(SYSTEM.merklDistributor()), baseIncrease);
        address[] memory tokens = new address[](3);
        tokens[0] = reward;
        tokens[1] = reward;
        tokens[2] = address(SYSTEM.usdc());
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = merklClaimable[address(wallet)][reward];
        amounts[1] = amounts[0];
        amounts[2] = merklClaimable[address(wallet)][address(SYSTEM.usdc())];
        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        proofs[2] = new bytes32[](0);
        address adapter = address(SYSTEM.merklAdapter());
        address target = address(SYSTEM.merklDistributor());
        _prepareExecution(wallet, adapter, target);
        bytes memory claimData = abi.encodeCall(SYSTEM.merklAdapter().claim, (tokens, amounts, proofs));
        vm.recordLogs();
        vm.prank(operator);
        wallet.executeViaAdapter(adapter, target, claimData);
        _captureFees();
        _recordYield(wallet, baseIncrease);
        authorizedGains += baseIncrease;
        merklCalls++;
        uint256 balance = SYSTEM.rewardToken().balanceOf(address(wallet));
        if (balance > 0) {
            uint256 received = _swapReward(wallet, reward, dexSeed % 3, balance);
            authorizedGains += received;
            _recordYield(wallet, received);
        }
    }

    function operatorClaimsMoonwellAndSells(uint8 ownerSeed, uint8 dexSeed) public {
        AgentWallet wallet = vaultWallets[ownerSeed % 2];
        uint256 wellAmount = 1e18;
        uint256 baseAmount = 1e6;
        SYSTEM.wellToken().mint(address(dualRewards), wellAmount);
        SYSTEM.usdc().mint(address(dualRewards), baseAmount);
        address[] memory markets = new address[](2);
        markets[0] = address(SYSTEM.compoundV2Vault());
        markets[1] = address(SYSTEM.compoundV3Market());
        address adapter = address(SYSTEM.moonwellRewardAdapter());
        address target = address(dualRewards);
        _prepareExecution(wallet, adapter, target);
        bytes memory claimData = abi.encodeCall(SYSTEM.moonwellRewardAdapter().claimReward, (address(wallet), markets));
        vm.recordLogs();
        vm.prank(operator);
        wallet.executeViaAdapter(adapter, target, claimData);
        _captureFees();
        _recordYield(wallet, baseAmount);
        authorizedGains += baseAmount;
        moonwellCalls++;
        uint256 balance = SYSTEM.wellToken().balanceOf(address(wallet));
        if (balance > 0) {
            uint256 received = _swapReward(wallet, address(SYSTEM.wellToken()), dexSeed % 3, balance);
            authorizedGains += received;
            _recordYield(wallet, received);
        }
    }

    function operatorRunsBorrowSwapAndRepays(uint8 ownerSeed, uint8 dexSeed, uint96 amountSeed) public {
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        _ensureMarketDebt(wallet, 0);
        uint256 totalDebt = _totalDebt(wallet);
        _ensureWalletWeth(wallet, totalDebt);
        for (uint8 marketIndex = 1; marketIndex < 3; marketIndex++) {
            uint256 debt = _marketDebt(wallet, marketIndex);
            if (debt > 0) {
                _executeLending(wallet, marketIndex, _repayCall(marketIndex, type(uint256).max));
                lendingRepayCalls[marketIndex]++;
            }
            uint256 collateral = _lendingCollateral(wallet, marketIndex);
            if (collateral > 0) {
                uint256 heldBefore = collateral;
                bytes memory result = _executeLending(wallet, marketIndex, _withdrawCollateralCall(marketIndex, type(uint256).max));
                uint256 out = abi.decode(abi.decode(result, (bytes)), (uint256));
                _updateBasisAfterWithdrawal(wallet, _collateralPosition(marketIndex), heldBefore, heldBefore, out);
                lendingWithdrawalCalls[marketIndex]++;
            }
        }
        uint256 debt = _marketDebt(wallet, 0);
        _ensureWalletWeth(wallet, debt);
        uint256 held = SYSTEM.weth().balanceOf(address(wallet));
        if (held > 0) {
            address owner = wallet.owner();
            address weth = address(SYSTEM.weth());
            vm.recordLogs();
            vm.prank(owner);
            wallet.withdrawAssetToUser(owner, weth, held);
            _captureFees();
        }
        uint256 sellAmount = bound(uint256(amountSeed), 1e6, 10e6);
        _ensureWalletBase(wallet, sellAmount + SYSTEM.borrowFeeTracker().feesOwedInBaseAsset(address(wallet)));
        uint256 buyAmount = SYSTEM.priceOracle().quote(address(SYSTEM.usdc()), address(SYSTEM.weth()), sellAmount);
        SYSTEM.aaveV3LendingPool().growDebt(address(SYSTEM.weth()), address(wallet), buyAmount);
        unreportedDebt[address(wallet)][_debtPosition(0)] += buyAmount;
        allowedLosses += _quoteWethToUsdc(buyAmount);
        _executeLending(wallet, 0, _checkpointCall(0));
        lendingCheckpointCalls[0]++;
        _ensureWalletBase(wallet, sellAmount + wallet.feeTracker().feesOwedInBaseAsset(address(wallet)));

        uint8 dex = dexSeed % 3;
        address adapter = _swapAdapter(dex);
        address router = _swapRouter(dex);
        _prepareExecution(wallet, adapter, router);
        _setRouterBuyAmount(dex, buyAmount);
        _ensureRouterLiquidity(dex, address(SYSTEM.weth()), buyAmount);
        bytes memory route = _borrowRoute(dex, address(SYSTEM.usdc()), address(SYSTEM.weth()));
        bytes memory swapData = _borrowSwapCall(dex, route, sellAmount);
        vm.recordLogs();
        vm.prank(operator);
        wallet.executeViaAdapter(adapter, router, swapData);
        _captureFees();
        uint256 maxSlippage = Math.mulDiv(sellAmount, SYSTEM.BORROW_SWAP_MAX_SLIPPAGE_BPS(), 10_000, Math.Rounding.Ceil);
        allowedLosses += maxSlippage + 2;
        _executeLending(wallet, 0, _repayCall(0, buyAmount));
        lendingRepayCalls[0]++;
        borrowSwapCalls[dex]++;
    }

    function operatorMovesBetweenWallets(uint8 ownerSeed, uint96 amountSeed, bool vaultToBorrow) public {
        uint8 ownerIndex = ownerSeed % 2;
        AgentWallet sender = vaultToBorrow ? vaultWallets[ownerIndex] : borrowWallets[ownerIndex];
        AgentWallet receiver = vaultToBorrow ? borrowWallets[ownerIndex] : vaultWallets[ownerIndex];
        uint256 amount = bound(uint256(amountSeed), 1e6, 20e6);
        uint256 required = amount + sender.feeTracker().feesOwedInBaseAsset(address(sender));
        _ensureWalletBase(sender, required);
        address adapter = address(SYSTEM.agentTransferAdapter());
        address token = address(SYSTEM.usdc());
        _prepareExecution(sender, adapter, adapter);
        bytes memory data = abi.encodeWithSignature("transfer(address,address,uint256)", token, address(receiver), amount);
        vm.recordLogs();
        vm.prank(operator);
        sender.executeViaAdapter(adapter, adapter, data);
        _captureFees();
        transferCalls++;
    }

    function ownerWithdrawsOneAsset(uint8 walletSeed, uint96 amountSeed) public {
        AgentWallet wallet = _wallet(walletSeed);
        uint256 available = wallet.withdrawableBalance(address(SYSTEM.usdc()));
        if (available == 0) return;
        uint256 amount = bound(uint256(amountSeed), 1, available);
        address owner = wallet.owner();
        address base = address(SYSTEM.usdc());
        vm.recordLogs();
        vm.prank(owner);
        wallet.withdrawAssetToUser(owner, base, amount);
        _captureFees();
        singleWithdrawalCalls++;
    }

    function ownerWithdrawsAllBase(uint8 walletSeed) public {
        AgentWallet wallet = _wallet(walletSeed);
        address owner = wallet.owner();
        address base = address(SYSTEM.usdc());
        vm.recordLogs();
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, base);
        _captureFees();
        allWithdrawalCalls++;
    }

    function ownerWithdrawsBatch(uint8 ownerSeed, uint96 amountSeed) public {
        AgentWallet wallet = borrowWallets[ownerSeed % 2];
        _ensureMarketDebt(wallet, 0);
        uint256 available = wallet.withdrawableBalance(address(SYSTEM.usdc()));
        uint256 baseAmount = available == 0 ? 0 : bound(uint256(amountSeed), 1, available);
        address[] memory assets = new address[](2);
        assets[0] = address(SYSTEM.usdc());
        assets[1] = address(SYSTEM.weth());
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = baseAmount;
        amounts[1] = SYSTEM.weth().balanceOf(address(wallet));
        address owner = wallet.owner();
        vm.recordLogs();
        vm.prank(owner);
        wallet.withdrawAssetsToUser(owner, assets, amounts);
        _captureFees();
        batchWithdrawalCalls++;
    }

    function ownerWithdrawsEth(uint8 walletSeed, bool withdrawAll) public {
        AgentWallet wallet = _wallet(walletSeed);
        vm.deal(address(wallet), 1 ether);
        address owner = wallet.owner();
        vm.prank(owner);
        if (withdrawAll) wallet.withdrawAllEthToUser(owner);
        else wallet.withdrawEthToUser(owner, 0.5 ether);
        ethWithdrawalCalls++;
    }

    function ownerBlocksOrUnblocks(uint8 walletSeed, uint8 targetSeed, bool blockIt, bool adapterBlock) public {
        AgentWallet wallet = _wallet(walletSeed);
        uint8 adapterIndex = targetSeed % 4;
        address adapter = _vaultAdapter(adapterIndex);
        address target = _vaultTarget(adapterIndex);
        vm.prank(wallet.owner());
        if (adapterBlock) {
            if (blockIt) wallet.blockAdapter(adapter);
            else wallet.unblockAdapter(adapter);
        } else {
            if (blockIt) wallet.blockTarget(target);
            else wallet.unblockTarget(target);
        }
        ownerBlockCalls++;
    }

    function adminChangesRegistryThenSyncs(uint8 registrySeed) public {
        if (registrySeed % 2 == 0) {
            address target = address(SYSTEM.erc4626Vault());
            SYSTEM.vaultRegistry().removeTarget(target);
            for (uint256 i; i < 2; i++) {
                vaultWallets[i].syncFromFactory();
            }
            SYSTEM.vaultRegistry().setTargetAdapter(target, address(SYSTEM.erc4626Adapter()));
            for (uint256 i; i < 2; i++) {
                vaultWallets[i].syncFromFactory();
            }
        } else {
            bytes memory market = SYSTEM.aaveV3Market();
            address target = SYSTEM.aaveV3LendingAdapter().marketTarget(market);
            SYSTEM.borrowRegistry().removeTarget(target);
            for (uint256 i; i < 2; i++) {
                borrowWallets[i].syncFromFactory();
            }
            SYSTEM.borrowRegistry().setTargetAdapter(target, address(SYSTEM.aaveV3LendingAdapter()));
            for (uint256 i; i < 2; i++) {
                borrowWallets[i].syncFromFactory();
            }
        }
        registrySyncCalls++;
    }

    function timePasses(uint32 secondsSeed) public {
        uint256 elapsed = bound(uint256(secondsSeed), 1 days, 30 days);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        _refreshPriceFeeds();
        timeAdvanceCalls++;
    }

    function marketPricesMove(uint96 priceSeed) public {
        uint256 beforeValue = totalOwnerValue();
        uint256 price = bound(uint256(priceSeed), 1_000e8, 3_000e8);
        _setMarketPrice(price);
        uint256 afterValue = totalOwnerValue();
        if (afterValue < beforeValue) allowedLosses += beforeValue - afterValue;
        priceMoveCalls++;
    }

    function assertPositionAccounting() external view {
        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            for (uint8 vaultIndex; vaultIndex < 4; vaultIndex++) {
                address target = _vaultTarget(vaultIndex);
                assertEq(_vaultPosition(vaultWallet, vaultIndex), IERC20(target).balanceOf(address(vaultWallet)));
                assertEq(basisGhost[address(vaultWallet)][target], SYSTEM.vaultYieldFeeModule().costBasis(address(vaultWallet), target));
            }

            AgentWallet borrowWallet = borrowWallets[i];
            for (uint8 marketIndex; marketIndex < 3; marketIndex++) {
                address collateralPosition = _collateralPosition(marketIndex);
                assertEq(basisGhost[address(borrowWallet)][collateralPosition], SYSTEM.borrowYieldFeeModule().costBasis(address(borrowWallet), collateralPosition));
                address position = _debtPosition(marketIndex);
                (uint128 lastDebt, uint64 lastAccrual, uint192 lastPrice) = SYSTEM.borrowFeeModule().debtPositions(address(borrowWallet), position);
                assertEq(lastDebt, reportedDebt[address(borrowWallet)][position]);
                assertEq(lastAccrual, reportedAt[address(borrowWallet)][position]);
                assertEq(lastPrice, reportedPrice[address(borrowWallet)][position]);
                assertEq(_marketDebt(borrowWallet, marketIndex), reportedDebt[address(borrowWallet)][position] + unreportedDebt[address(borrowWallet)][position]);
            }
            uint256 sumDebt = reportedDebt[address(borrowWallet)][_debtPosition(0)] + reportedDebt[address(borrowWallet)][_debtPosition(1)] + reportedDebt[address(borrowWallet)][_debtPosition(2)];
            assertEq(SYSTEM.borrowFeeModule().tokenDebt(address(borrowWallet), address(SYSTEM.weth())), sumDebt);
        }
        _assertPositionsBelongToWallets();
    }

    function assertFeeAccounting() external view {
        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            address vaultAddress = address(vaultWallet);
            uint256 vaultRate = SYSTEM.vaultYieldFeeModule().walletPlan(vaultAddress).rateBps;
            uint256 vaultBudget = Math.mulDiv(realizedYield[vaultAddress], vaultRate, 10_000, Math.Rounding.Ceil) + yieldActions[vaultAddress];
            assertEq(yieldCharged[vaultAddress], SYSTEM.vaultYieldFeeModule().feesOwed(vaultAddress) + yieldPaid[vaultAddress]);
            assertLe(yieldCharged[vaultAddress], vaultBudget);

            AgentWallet borrowWallet = borrowWallets[i];
            address borrowAddress = address(borrowWallet);
            uint256 borrowYieldRate = SYSTEM.borrowYieldFeeModule().walletPlan(borrowAddress).rateBps;
            uint256 borrowYieldBudget = Math.mulDiv(realizedYield[borrowAddress], borrowYieldRate, 10_000, Math.Rounding.Ceil) + yieldActions[borrowAddress];
            assertEq(yieldCharged[borrowAddress], SYSTEM.borrowYieldFeeModule().feesOwed(borrowAddress) + yieldPaid[borrowAddress]);
            assertLe(yieldCharged[borrowAddress], borrowYieldBudget);
            assertEq(borrowFeeCharged[borrowAddress], SYSTEM.borrowFeeModule().feesOwed(borrowAddress) + borrowFeePaid[borrowAddress]);
            assertEq(borrowFeeCharged[borrowAddress], expectedBorrowFees[borrowAddress]);
        }
        assertEq(SYSTEM.usdc().balanceOf(SYSTEM.feeCollector()), collectorBalanceAtStart + totalFeesPaid);
    }

    function assertWithdrawableBalances() external view {
        for (uint256 i; i < 2; i++) {
            _assertWithdrawable(vaultWallets[i], false);
            _assertWithdrawable(borrowWallets[i], true);
        }
    }

    function assertOwnerValueBound() external view {
        assertGe(totalOwnerValue() + totalFeesPaid + allowedLosses + roundingAllowance, initialOwnerValue + authorizedGains);
    }

    function closeOutAll() external {
        uint256 ownersUsdcBefore = SYSTEM.usdc().balanceOf(owners[0]) + SYSTEM.usdc().balanceOf(owners[1]);
        uint256 walletsUsdcBefore = _allWalletBaseBalance();
        uint256 positionsBefore = _allPositionValue();
        uint256 ownersWethBefore = SYSTEM.weth().balanceOf(owners[0]) + SYSTEM.weth().balanceOf(owners[1]);
        uint256 walletsWethBefore = _allWalletWethBalance();
        uint256 debtBefore = _allDebtBalance();
        uint256 collectorBefore = SYSTEM.usdc().balanceOf(SYSTEM.feeCollector());
        uint256 ownersEthBefore = owners[0].balance + owners[1].balance;
        uint256 walletsEthBefore = address(vaultWallets[0]).balance + address(vaultWallets[1]).balance + address(borrowWallets[0]).balance + address(borrowWallets[1]).balance;
        uint256 mintedWethBefore = wethCapitalMinted;

        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            for (uint8 vaultIndex; vaultIndex < 4; vaultIndex++) {
                _closeVaultPosition(vaultWallet, vaultIndex);
            }
            _sellIfHeld(vaultWallet, address(SYSTEM.rewardToken()));
            _sellIfHeld(vaultWallet, address(SYSTEM.wellToken()));

            AgentWallet borrowWallet = borrowWallets[i];
            uint256 totalDebt = _totalDebt(borrowWallet);
            _ensureWalletWeth(borrowWallet, totalDebt);
            for (uint8 marketIndex; marketIndex < 3; marketIndex++) {
                uint256 debt = _marketDebt(borrowWallet, marketIndex);
                if (debt > 0) {
                    _executeLending(borrowWallet, marketIndex, _repayCall(marketIndex, type(uint256).max));
                    lendingRepayCalls[marketIndex]++;
                }
                uint256 collateral = _lendingCollateral(borrowWallet, marketIndex);
                if (collateral > 0) {
                    bytes memory result = _executeLending(borrowWallet, marketIndex, _withdrawCollateralCall(marketIndex, type(uint256).max));
                    uint256 assetsOut = abi.decode(abi.decode(result, (bytes)), (uint256));
                    _updateBasisAfterWithdrawal(borrowWallet, _collateralPosition(marketIndex), collateral, collateral, assetsOut);
                    lendingWithdrawalCalls[marketIndex]++;
                }
            }
            _sellIfHeld(borrowWallet, address(SYSTEM.rewardToken()));
            _sellIfHeld(borrowWallet, address(SYSTEM.wellToken()));
        }

        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            _withdrawAllToOwner(vaultWallet, address(SYSTEM.usdc()));
            AgentWallet borrowWallet = borrowWallets[i];
            _withdrawAllToOwner(borrowWallet, address(SYSTEM.usdc()));
            if (SYSTEM.borrowFeeModule().isBorrowedToken(address(borrowWallet), address(SYSTEM.weth()))) {
                _withdrawAllToOwner(borrowWallet, address(SYSTEM.weth()));
            }
            vm.prank(owners[i]);
            vaultWallet.withdrawAllEthToUser(owners[i]);
            vm.prank(owners[i]);
            borrowWallet.withdrawAllEthToUser(owners[i]);
        }

        uint256 ownerUsdcAfter = SYSTEM.usdc().balanceOf(owners[0]) + SYSTEM.usdc().balanceOf(owners[1]);
        uint256 collectorPaidDuringExit = SYSTEM.usdc().balanceOf(SYSTEM.feeCollector()) - collectorBefore;
        assertGe(ownerUsdcAfter + collectorPaidDuringExit + 10, ownersUsdcBefore + walletsUsdcBefore + positionsBefore);
        uint256 ownerWethAfter = SYSTEM.weth().balanceOf(owners[0]) + SYSTEM.weth().balanceOf(owners[1]);
        assertApproxEqAbs(ownerWethAfter, ownersWethBefore + walletsWethBefore + wethCapitalMinted - mintedWethBefore - debtBefore, roundingAllowance);
        uint256 ownersEthAfter = owners[0].balance + owners[1].balance;
        assertEq(ownersEthAfter, ownersEthBefore + walletsEthBefore);
        _assertEverythingEmptyOrOnlyUnpayableFeesRemain();
    }

    function runRepresentativeWorkflows() public {
        for (uint8 i; i < 4; i++) {
            operatorDepositsVault(0, i, uint96(50 * USDC_UNIT), false);
            operatorDepositsVault(1, i, uint96(40 * USDC_UNIT), true);
            operatorChangesVaultValue(0, i, uint96(100 * USDC_UNIT), 0);
            operatorChangesVaultValue(0, i, uint96(1 * USDC_UNIT), 1);
            operatorWithdrawsVault(0, i, false);
            operatorWithdrawsVault(1, i, true);
        }
        ownerDonatesToVault(0, uint96(2 * USDC_UNIT));
        for (uint8 i; i < 3; i++) {
            operatorLendingWorkflow(0, i, uint96(100 * USDC_UNIT), uint96(1e16));
            operatorLendingWorkflow(1, i, uint96(100 * USDC_UNIT), uint96(1e16));
            operatorAccruesLendingCollateral(1, i, uint96(1 * USDC_UNIT));
            operatorCheckpointsMarket(0, i);
            operatorRepaysMarket(0, i, 1, false);
            operatorRepaysMarket(0, i, type(uint96).max, true);
            operatorWithdrawsCollateral(0, i, true);
        }
        protocolAccruesInterest(0, uint96(1e14));
        operatorCheckpointsMarket(0, 0);
        operatorRunsBorrowSwapAndRepays(0, 0, uint96(10 * USDC_UNIT));
        operatorRunsBorrowSwapAndRepays(0, 1, uint96(10 * USDC_UNIT));
        operatorRunsBorrowSwapAndRepays(1, 2, uint96(10 * USDC_UNIT));
        operatorClaimsMerklAndSells(0, 0, uint96(1e18));
        operatorClaimsMerklAndSells(1, 1, uint96(1e18));
        operatorClaimsMoonwellAndSells(0, 2);
        operatorMovesBetweenWallets(0, uint96(2 * USDC_UNIT), true);
        operatorMovesBetweenWallets(1, uint96(2 * USDC_UNIT), false);
        ownerWithdrawsOneAsset(0, uint96(1 * USDC_UNIT));
        ownerWithdrawsBatch(0, uint96(1 * USDC_UNIT));
        ownerWithdrawsAllBase(2);
        ownerWithdrawsEth(0, true);
        ownerBlocksOrUnblocks(0, 0, true, true);
        ownerBlocksOrUnblocks(0, 0, false, true);
        ownerBlocksOrUnblocks(0, 1, true, false);
        ownerBlocksOrUnblocks(0, 1, false, false);
        adminChangesRegistryThenSyncs(0);
        adminChangesRegistryThenSyncs(1);
        timePasses(1 days);
        marketPricesMove(uint96(2_500e8));
    }

    function assertEveryWorkflowWasCalled() external view {
        for (uint256 i; i < 4; i++) {
            assertGt(vaultDepositCalls[i], 0);
            assertGt(vaultWithdrawalCalls[i], 0);
            assertGt(vaultGainCalls[i], 0);
            assertGt(vaultLossCalls[i], 0);
        }
        for (uint256 i; i < 3; i++) {
            assertGt(lendingSupplyCalls[i], 0);
            assertGt(lendingBorrowCalls[i], 0);
            assertGt(lendingRepayCalls[i], 0);
            assertGt(lendingWithdrawalCalls[i], 0);
            assertGt(lendingCheckpointCalls[i], 0);
            assertGt(rewardSaleCalls[i], 0);
            assertGt(borrowSwapCalls[i], 0);
        }
        assertGt(lendingCollateralYieldCalls, 0);
        assertGt(interestAccrualCalls, 0);
        assertGt(merklCalls, 0);
        assertGt(moonwellCalls, 0);
        assertGt(transferCalls, 0);
        assertGt(singleWithdrawalCalls, 0);
        assertGt(allWithdrawalCalls, 0);
        assertGt(batchWithdrawalCalls, 0);
        assertGt(ethWithdrawalCalls, 0);
        assertGt(ownerBlockCalls, 0);
        assertGt(registrySyncCalls, 0);
        assertGt(timeAdvanceCalls, 0);
        assertGt(priceMoveCalls, 0);
        assertGt(ownerDonationCalls, 0);
    }

    function logWorkflowCalls() external view {
        for (uint256 i; i < 4; i++) {
            console2.log("poweruser vault deposit adapter", i, vaultDepositCalls[i]);
            console2.log("poweruser vault withdrawal adapter", i, vaultWithdrawalCalls[i]);
            console2.log("poweruser vault gain adapter", i, vaultGainCalls[i]);
            console2.log("poweruser vault loss adapter", i, vaultLossCalls[i]);
        }
        for (uint256 i; i < 3; i++) {
            console2.log("poweruser lending supply market", i, lendingSupplyCalls[i]);
            console2.log("poweruser lending borrow market", i, lendingBorrowCalls[i]);
            console2.log("poweruser lending repay market", i, lendingRepayCalls[i]);
            console2.log("poweruser lending withdrawal market", i, lendingWithdrawalCalls[i]);
            console2.log("poweruser lending checkpoint market", i, lendingCheckpointCalls[i]);
            console2.log("poweruser reward sales dex", i, rewardSaleCalls[i]);
            console2.log("poweruser borrow swaps dex", i, borrowSwapCalls[i]);
        }
        console2.log("poweruser lending collateral yield", lendingCollateralYieldCalls);
        console2.log("poweruser interest accrual", interestAccrualCalls);
        console2.log("poweruser Merkl claims", merklCalls);
        console2.log("poweruser Moonwell claims", moonwellCalls);
        console2.log("poweruser agent transfers", transferCalls);
        console2.log("poweruser single withdrawals", singleWithdrawalCalls);
        console2.log("poweruser all withdrawals", allWithdrawalCalls);
        console2.log("poweruser batch withdrawals", batchWithdrawalCalls);
        console2.log("poweruser ETH withdrawals", ethWithdrawalCalls);
        console2.log("poweruser owner blocklists", ownerBlockCalls);
        console2.log("poweruser admin registry changes and syncs", registrySyncCalls);
        console2.log("poweruser time advances", timeAdvanceCalls);
        console2.log("poweruser market price moves", priceMoveCalls);
        console2.log("poweruser owner vault donations", ownerDonationCalls);
    }

    function totalOwnerValue() public view returns (uint256 value) {
        uint256 assets;
        uint256 debts;
        for (uint256 i; i < 2; i++) {
            assets += SYSTEM.usdc().balanceOf(owners[i]);
            AgentWallet vaultWallet = vaultWallets[i];
            AgentWallet borrowWallet = borrowWallets[i];
            assets += SYSTEM.usdc().balanceOf(address(vaultWallet)) + SYSTEM.usdc().balanceOf(address(borrowWallet));
            for (uint8 vaultIndex; vaultIndex < 4; vaultIndex++) {
                assets += _vaultPositionValue(vaultWallet, vaultIndex);
            }
            for (uint8 marketIndex; marketIndex < 3; marketIndex++) {
                assets += _lendingCollateral(borrowWallet, marketIndex);
            }
            debts += _totalDebt(borrowWallet);
        }
        assets += _quoteWethToUsdc(SYSTEM.weth().balanceOf(owners[0]) + SYSTEM.weth().balanceOf(owners[1]) + _allWalletWethBalance());
        debts = _quoteWethToUsdc(debts);
        return assets > debts ? assets - debts : 0;
    }

    function _assertWithdrawable(AgentWallet wallet, bool borrowProfile) private view {
        uint256 baseBalance = SYSTEM.usdc().balanceOf(address(wallet));
        uint256 feesOwed = wallet.feeTracker().feesOwedInBaseAsset(address(wallet));
        uint256 expectedBase = baseBalance > feesOwed ? baseBalance - feesOwed : 0;
        assertEq(wallet.withdrawableBalance(address(SYSTEM.usdc())), expectedBase);
        bool accountedBorrowed = borrowProfile && SYSTEM.borrowFeeModule().isBorrowedToken(address(wallet), address(SYSTEM.weth()));
        assertEq(wallet.withdrawableBalance(address(SYSTEM.weth())), accountedBorrowed ? SYSTEM.weth().balanceOf(address(wallet)) : 0);
        assertEq(wallet.withdrawableBalance(address(SYSTEM.rewardToken())), 0);
        assertEq(wallet.withdrawableBalance(address(SYSTEM.wellToken())), 0);
    }

    function _assertPositionsBelongToWallets() private view {
        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            assertEq(SYSTEM.erc4626Vault().balanceOf(owners[i]), 0);
            assertEq(SYSTEM.aaveV3Vault().balanceOf(owners[i]), 0);
            assertEq(SYSTEM.compoundV2Vault().balanceOf(owners[i]), 0);
            assertEq(SYSTEM.compoundV3Market().balanceOf(owners[i]), 0);
            assertEq(SYSTEM.erc4626Vault().balanceOf(address(vaultWallet)), _vaultPosition(vaultWallet, 0));
            assertEq(SYSTEM.aaveV3Vault().balanceOf(address(vaultWallet)), _vaultPosition(vaultWallet, 1));
            assertEq(SYSTEM.compoundV2Vault().balanceOf(address(vaultWallet)), _vaultPosition(vaultWallet, 2));
            assertEq(SYSTEM.compoundV3Market().balanceOf(address(vaultWallet)), _vaultPosition(vaultWallet, 3));

            AgentWallet borrowWallet = borrowWallets[i];
            assertEq(SYSTEM.aaveV3CollateralAToken().balanceOf(owners[i]), 0);
            assertEq(SYSTEM.aaveV3CollateralAToken().balanceOf(address(borrowWallet)), _lendingCollateral(borrowWallet, 0));
            assertEq(SYSTEM.aaveV4Spoke().getUserSuppliedAssets(1, owners[i]), 0);
            assertEq(SYSTEM.aaveV4Spoke().getUserSuppliedAssets(1, address(borrowWallet)), _lendingCollateral(borrowWallet, 1));
            (address morphoAddress, IMorphoBlue.MarketParams memory params) = abi.decode(SYSTEM.morphoMarket(), (address, IMorphoBlue.MarketParams));
            bytes32 morphoId = keccak256(abi.encode(params));
            (,, uint128 ownerCollateral) = SYSTEM.morpho().position(morphoId, owners[i]);
            (,, uint128 walletCollateral) = SYSTEM.morpho().position(morphoId, address(borrowWallet));
            assertEq(ownerCollateral, 0);
            assertEq(walletCollateral, _lendingCollateral(borrowWallet, 2));
            morphoAddress;
        }
    }

    function _assertEverythingEmptyOrOnlyUnpayableFeesRemain() private view {
        for (uint256 i; i < 2; i++) {
            AgentWallet vaultWallet = vaultWallets[i];
            AgentWallet borrowWallet = borrowWallets[i];
            assertEq(SYSTEM.usdc().balanceOf(address(vaultWallet)), 0);
            assertEq(SYSTEM.usdc().balanceOf(address(borrowWallet)), 0);
            assertEq(SYSTEM.weth().balanceOf(address(vaultWallet)), 0);
            assertEq(SYSTEM.weth().balanceOf(address(borrowWallet)), 0);
            assertEq(SYSTEM.rewardToken().balanceOf(address(vaultWallet)), 0);
            assertEq(SYSTEM.rewardToken().balanceOf(address(borrowWallet)), 0);
            assertEq(SYSTEM.wellToken().balanceOf(address(vaultWallet)), 0);
            assertEq(SYSTEM.wellToken().balanceOf(address(borrowWallet)), 0);
            for (uint8 vaultIndex; vaultIndex < 4; vaultIndex++) {
                assertEq(_vaultPosition(vaultWallet, vaultIndex), 0);
            }
            for (uint8 marketIndex; marketIndex < 3; marketIndex++) {
                assertEq(_marketDebt(borrowWallet, marketIndex), 0);
                assertEq(_lendingCollateral(borrowWallet, marketIndex), 0);
                (uint128 lastDebt,,) = SYSTEM.borrowFeeModule().debtPositions(address(borrowWallet), _debtPosition(marketIndex));
                assertEq(lastDebt, 0);
            }
            uint256 owed = borrowWallet.feeTracker().feesOwedInBaseAsset(address(borrowWallet));
            assertTrue(owed == 0 || SYSTEM.usdc().balanceOf(address(borrowWallet)) == 0);
            uint256 vaultOwed = vaultWallet.feeTracker().feesOwedInBaseAsset(address(vaultWallet));
            assertTrue(vaultOwed == 0 || SYSTEM.usdc().balanceOf(address(vaultWallet)) == 0);
        }
    }

    function _closeVaultPosition(AgentWallet wallet, uint8 index) private {
        uint256 held = _vaultPosition(wallet, index);
        if (held == 0) return;
        address adapter = _vaultAdapter(index);
        address target = _vaultTarget(index);
        _prepareExecution(wallet, adapter, target);
        vm.recordLogs();
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(adapter, target, abi.encodeWithSignature("withdraw(uint256)", held));
        _captureFees();
        uint256 out = abi.decode(abi.decode(result, (bytes)), (uint256));
        _updateBasisAfterWithdrawal(wallet, target, held, held, out);
        vaultWithdrawalCalls[index]++;
    }

    function _withdrawAllToOwner(AgentWallet wallet, address token) private {
        address owner = wallet.owner();
        vm.recordLogs();
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, token);
        _captureFees();
    }

    function _sellIfHeld(AgentWallet wallet, address token) private {
        uint256 amount = IERC20(token).balanceOf(address(wallet));
        if (amount == 0) return;
        uint256 received = _swapReward(wallet, token, 0, amount);
        _recordYield(wallet, received);
    }

    function _swapReward(AgentWallet wallet, address token, uint8 dex, uint256 amount) private returns (uint256 received) {
        address adapter = _swapAdapter(dex);
        address router = _swapRouter(dex);
        _prepareExecution(wallet, adapter, router);
        uint256 output = SYSTEM.priceOracle().quote(token, address(SYSTEM.usdc()), amount);
        if (output == 0) output = 1;
        _setRouterBuyAmount(dex, output);
        _ensureRouterLiquidity(dex, address(SYSTEM.usdc()), output);
        bytes memory route = _rewardRoute(dex, token, address(SYSTEM.usdc()));
        bytes memory data = _rewardSwapCall(dex, route, token, amount, block.timestamp);
        vm.recordLogs();
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(adapter, router, data);
        _captureFees();
        received = abi.decode(abi.decode(result, (bytes)), (uint256));
        rewardSaleCalls[dex]++;
    }

    function _supplyCollateral(AgentWallet wallet, uint8 marketIndex, uint256 amount) private {
        _ensureWalletBase(wallet, amount + wallet.feeTracker().feesOwedInBaseAsset(address(wallet)));
        address adapter = _lendingAdapter(marketIndex);
        address target = _marketTarget(marketIndex);
        _prepareExecution(wallet, adapter, target);
        bytes memory supplyData = _supplyCall(marketIndex, amount);
        vm.recordLogs();
        vm.prank(operator);
        bytes memory result = wallet.executeViaAdapter(adapter, target, supplyData);
        _captureFees();
        uint256 supplied = abi.decode(abi.decode(result, (bytes)), (uint256));
        basisGhost[address(wallet)][_collateralPosition(marketIndex)] += supplied;
        lendingSupplyCalls[marketIndex]++;
        roundingAllowance++;
    }

    function _ensureMarketDebt(AgentWallet wallet, uint8 marketIndex) private {
        if (_lendingCollateral(wallet, marketIndex) == 0) _supplyCollateral(wallet, marketIndex, 100e6);
        if (_marketDebt(wallet, marketIndex) == 0) {
            _executeLending(wallet, marketIndex, _borrowCall(marketIndex, 1e15));
            lendingBorrowCalls[marketIndex]++;
        }
    }

    function _executeLending(AgentWallet wallet, uint8 marketIndex, bytes memory data) private returns (bytes memory result) {
        address position = _debtPosition(marketIndex);
        YieldSeekerBorrowFeeModule module = SYSTEM.borrowFeeModule();
        (uint128 lastDebt, uint64 lastAccrual, uint192 lastPrice) = module.debtPositions(address(wallet), position);
        assertEq(lastDebt, reportedDebt[address(wallet)][position]);
        assertEq(lastAccrual, reportedAt[address(wallet)][position]);
        assertEq(lastPrice, reportedPrice[address(wallet)][position]);
        uint256 feeInDebtToken;
        if (lastDebt > 0 && lastPrice > 0) {
            uint256 rate = module.walletPlan(address(wallet)).rateBps;
            feeInDebtToken = Math.mulDiv(uint256(lastDebt), rate * (block.timestamp - uint256(lastAccrual)), YEAR * 10_000, Math.Rounding.Ceil);
        }
        uint256 reportPrice = _marketPriceInBase(marketIndex);
        if (reportPrice == 0) reportPrice = lastPrice;
        uint256 expectedBaseFee = feeInDebtToken == 0 ? 0 : Math.mulDiv(feeInDebtToken, reportPrice, 1e36, Math.Rounding.Ceil);
        uint256 chargedBefore = borrowFeeCharged[address(wallet)];
        address adapter = _lendingAdapter(marketIndex);
        address target = _marketTarget(marketIndex);
        _prepareExecution(wallet, adapter, target);
        vm.recordLogs();
        vm.prank(operator);
        result = wallet.executeViaAdapter(adapter, target, data);
        _captureFees();
        uint256 charged = borrowFeeCharged[address(wallet)] - chargedBefore;
        assertEq(charged, expectedBaseFee);
        expectedBorrowFees[address(wallet)] += expectedBaseFee;
        uint256 debtAfter = _marketDebt(wallet, marketIndex);
        reportedDebt[address(wallet)][position] = debtAfter;
        reportedAt[address(wallet)][position] = block.timestamp;
        unreportedDebt[address(wallet)][position] = 0;
        uint256 price = _marketPriceInBase(marketIndex);
        if ((lastDebt > 0 || debtAfter > 0) && price > 0 && price <= type(uint192).max) {
            reportedPrice[address(wallet)][position] = price;
        }
    }

    function _updateBasisAfterWithdrawal(AgentWallet wallet, address target, uint256 heldBefore, uint256 spent, uint256 assetsOut) private {
        uint256 basis = basisGhost[address(wallet)][target];
        uint256 released;
        if (spent > 0 && heldBefore > 0) released = spent >= heldBefore ? basis : Math.mulDiv(basis, spent, heldBefore);
        basisGhost[address(wallet)][target] = basis - released;
        if (assetsOut > released) _recordYield(wallet, assetsOut - released);
    }

    function _recordYield(AgentWallet wallet, uint256 amount) private {
        if (amount > 0) {
            realizedYield[address(wallet)] += amount;
            yieldActions[address(wallet)]++;
        }
    }

    function _captureFees() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length < 2) continue;
            address wallet = address(uint160(uint256(entry.topics[1])));
            if (entry.emitter == address(SYSTEM.vaultYieldFeeModule()) || entry.emitter == address(SYSTEM.borrowYieldFeeModule())) {
                if (entry.topics[0] == YIELD_RECORDED) {
                    (, uint256 fee) = abi.decode(entry.data, (uint256, uint256));
                    yieldCharged[wallet] += fee;
                } else if (entry.topics[0] == FEE_PAID) {
                    uint256 amount = abi.decode(entry.data, (uint256));
                    yieldPaid[wallet] += amount;
                    totalFeesPaid += amount;
                }
            } else if (entry.emitter == address(SYSTEM.borrowFeeModule())) {
                if (entry.topics[0] == BORROW_FEE_CHARGED) {
                    (, uint256 feeInBaseAsset) = abi.decode(entry.data, (uint256, uint256));
                    borrowFeeCharged[wallet] += feeInBaseAsset;
                } else if (entry.topics[0] == FEE_PAID) {
                    uint256 amount = abi.decode(entry.data, (uint256));
                    borrowFeePaid[wallet] += amount;
                    totalFeesPaid += amount;
                }
            }
        }
    }

    function _applyVaultLoss(AgentWallet wallet, uint8 index, uint256 amountSeed) private returns (uint256 lossValue) {
        if (index == 0) {
            uint256 cash = SYSTEM.usdc().balanceOf(address(SYSTEM.erc4626Vault()));
            if (cash <= 100e6) return 0;
            uint256 loss = Math.min(bound(amountSeed, 1, 100e6), cash / 100);
            SYSTEM.usdc().burn(address(SYSTEM.erc4626Vault()), loss);
            return loss;
        }
        if (index == 1) {
            IERC20 aToken = SYSTEM.aaveV3Vault();
            uint256 shares = aToken.balanceOf(address(wallet));
            if (shares == 0) return 0;
            uint256 loss = Math.min(bound(amountSeed, 1, shares), Math.max(shares / 10, 1));
            vm.prank(address(wallet));
            aToken.transfer(LOSS_SINK, loss);
            return loss;
        }
        if (index == 2) {
            MockCToken market = SYSTEM.compoundV2Vault();
            uint256 shares = market.balanceOf(address(wallet));
            if (shares == 0) return 0;
            uint256 lostShares = Math.min(bound(amountSeed, 1, shares), Math.max(shares / 10, 1));
            lossValue = Math.mulDiv(lostShares, market.exchangeRateCurrent(), 1e18);
            vm.prank(address(wallet));
            market.transfer(LOSS_SINK, lostShares);
            return lossValue;
        }
        MockCompoundV3Comet market = SYSTEM.compoundV3Market();
        uint256 held = market.balanceOf(address(wallet));
        if (held == 0) return 0;
        uint256 lossAmount = Math.min(bound(amountSeed, 1, held), Math.max(held / 10, 1));
        address base = address(SYSTEM.usdc());
        vm.prank(address(wallet));
        market.withdraw(base, lossAmount);
        SYSTEM.usdc().burn(address(wallet), lossAmount);
        return lossAmount;
    }

    function _prepareExecution(AgentWallet wallet, address adapter, address target) private {
        if (wallet.isAdapterBlocked(adapter)) {
            vm.prank(wallet.owner());
            wallet.unblockAdapter(adapter);
        }
        if (wallet.isTargetBlocked(target)) {
            vm.prank(wallet.owner());
            wallet.unblockTarget(target);
        }
    }

    function _ensureWalletBase(AgentWallet wallet, uint256 amount) private {
        IERC20 baseToken = SYSTEM.usdc();
        uint256 balance = baseToken.balanceOf(address(wallet));
        if (balance >= amount) return;
        uint256 needed = amount - balance;
        address owner = wallet.owner();
        _ensureOwnerUsdc(owner, needed);
        vm.prank(owner);
        baseToken.transfer(address(wallet), needed);
    }

    function _ensureOwnerUsdc(address account, uint256 amount) private {
        uint256 balance = SYSTEM.usdc().balanceOf(account);
        if (balance >= amount) return;
        uint256 minted = amount - balance;
        SYSTEM.usdc().mint(account, minted);
        authorizedGains += minted;
    }

    function _ensureWalletWeth(AgentWallet wallet, uint256 amount) private {
        IERC20 weth = SYSTEM.weth();
        uint256 balance = weth.balanceOf(address(wallet));
        if (balance >= amount) return;
        uint256 needed = amount - balance;
        address owner = wallet.owner();
        _ensureOwnerWeth(owner, needed);
        vm.prank(owner);
        weth.transfer(address(wallet), needed);
    }

    function _ensureOwnerWeth(address account, uint256 amount) private {
        uint256 balance = SYSTEM.weth().balanceOf(account);
        if (balance >= amount) return;
        uint256 minted = amount - balance;
        SYSTEM.weth().mint(account, minted);
        wethCapitalMinted += minted;
        authorizedGains += _quoteWethToUsdc(minted);
    }

    function _refreshPriceFeeds() private {
        uint256 now_ = vm.getBlockTimestamp();
        SYSTEM.usdcPriceFeed().setPrice(1e8, now_);
        SYSTEM.wethPriceFeed().setPrice(SYSTEM.wethPriceFeed().answer(), now_);
        SYSTEM.rewardPriceFeed().setPrice(SYSTEM.rewardPriceFeed().answer(), now_);
        SYSTEM.wellPriceFeed().setPrice(SYSTEM.wellPriceFeed().answer(), now_);
    }

    function _setMarketPrice(uint256 price) private {
        SYSTEM.aaveV3LendingPool().setAssetPrice(address(SYSTEM.weth()), price);
        SYSTEM.aaveV4Spoke().setReservePrice(2, price);
        SYSTEM.morphoOracle().setPrice(1e56 / price);
        SYSTEM.usdcPriceFeed().setPrice(1e8, block.timestamp);
        SYSTEM.wethPriceFeed().setPrice(int256(price), block.timestamp);
    }

    function _vaultAdapter(uint8 index) private view returns (address) {
        if (index == 0) return address(SYSTEM.erc4626Adapter());
        if (index == 1) return address(SYSTEM.aaveV3Adapter());
        if (index == 2) return address(SYSTEM.compoundV2Adapter());
        return address(SYSTEM.compoundV3Adapter());
    }

    function _vaultTarget(uint8 index) private view returns (address) {
        if (index == 0) return address(SYSTEM.erc4626Vault());
        if (index == 1) return address(SYSTEM.aaveV3Vault());
        if (index == 2) return address(SYSTEM.compoundV2Vault());
        return address(SYSTEM.compoundV3Market());
    }

    function _vaultPosition(AgentWallet wallet, uint8 index) private view returns (uint256) {
        return IERC20(_vaultTarget(index)).balanceOf(address(wallet));
    }

    function _vaultPositionValue(AgentWallet wallet, uint8 index) private view returns (uint256) {
        if (index == 0) return SYSTEM.erc4626Vault().convertToAssets(SYSTEM.erc4626Vault().balanceOf(address(wallet)));
        if (index == 1) return SYSTEM.aaveV3Vault().balanceOf(address(wallet));
        if (index == 2) return Math.mulDiv(SYSTEM.compoundV2Vault().balanceOf(address(wallet)), SYSTEM.compoundV2Vault().exchangeRateCurrent(), 1e18);
        return SYSTEM.compoundV3Market().balanceOf(address(wallet));
    }

    function _lendingAdapter(uint8 index) private view returns (address) {
        if (index == 0) return address(SYSTEM.aaveV3LendingAdapter());
        if (index == 1) return address(SYSTEM.aaveV4LendingAdapter());
        return address(SYSTEM.morphoBlueLendingAdapter());
    }

    function _marketTarget(uint8 index) private view returns (address) {
        if (index == 0) return SYSTEM.aaveV3LendingAdapter().marketTarget(SYSTEM.aaveV3Market());
        if (index == 1) return SYSTEM.aaveV4LendingAdapter().marketTarget(SYSTEM.aaveV4Market());
        return SYSTEM.morphoBlueLendingAdapter().marketTarget(SYSTEM.morphoMarket());
    }

    function _collateralPosition(uint8 index) private view returns (address) {
        if (index == 0) return SYSTEM.aaveV3LendingAdapter().collateralPosition(SYSTEM.aaveV3Market());
        if (index == 1) return SYSTEM.aaveV4LendingAdapter().collateralPosition(SYSTEM.aaveV4Market());
        return SYSTEM.morphoBlueLendingAdapter().collateralPosition(SYSTEM.morphoMarket());
    }

    function _debtPosition(uint8 index) private view returns (address) {
        if (index == 0) return SYSTEM.aaveV3LendingAdapter().debtPosition(SYSTEM.aaveV3Market());
        if (index == 1) return SYSTEM.aaveV4LendingAdapter().debtPosition(SYSTEM.aaveV4Market());
        return SYSTEM.morphoBlueLendingAdapter().debtPosition(SYSTEM.morphoMarket());
    }

    function _lendingCollateral(AgentWallet wallet, uint8 index) private view returns (uint256) {
        if (index == 0) return SYSTEM.aaveV3CollateralAToken().balanceOf(address(wallet));
        if (index == 1) return SYSTEM.aaveV4Spoke().getUserSuppliedAssets(1, address(wallet));
        (, IMorphoBlue.MarketParams memory params) = abi.decode(SYSTEM.morphoMarket(), (address, IMorphoBlue.MarketParams));
        bytes32 id = keccak256(abi.encode(params));
        (,, uint128 collateral) = SYSTEM.morpho().position(id, address(wallet));
        return collateral;
    }

    function _marketDebt(AgentWallet wallet, uint8 index) private view returns (uint256) {
        if (index == 0) return SYSTEM.aaveV3VariableDebtToken().balanceOf(address(wallet));
        if (index == 1) return SYSTEM.aaveV4Spoke().getUserTotalDebt(2, address(wallet));
        (address morphoAddress, IMorphoBlue.MarketParams memory params) = abi.decode(SYSTEM.morphoMarket(), (address, IMorphoBlue.MarketParams));
        bytes32 id = keccak256(abi.encode(params));
        (, uint128 borrowShares,) = SYSTEM.morpho().position(id, address(wallet));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = SYSTEM.morpho().market(id);
        morphoAddress;
        if (borrowShares == 0) return 0;
        return Math.mulDiv(borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6, Math.Rounding.Ceil);
    }

    function _marketPriceInBase(uint8 index) private view returns (uint256) {
        if (index == 2) {
            uint256 price = SYSTEM.morphoOracle().price();
            return price == 0 ? 0 : Math.mulDiv(1e36, 1e36, price);
        }
        uint256 debtPrice;
        uint256 collateralPrice;
        uint256 collateralDecimals;
        uint256 debtDecimals;
        if (index == 0) {
            debtPrice = SYSTEM.aaveV3Oracle().getAssetPrice(address(SYSTEM.weth()));
            collateralPrice = SYSTEM.aaveV3Oracle().getAssetPrice(address(SYSTEM.usdc()));
            collateralDecimals = SYSTEM.usdc().decimals();
            debtDecimals = SYSTEM.weth().decimals();
        } else {
            debtPrice = SYSTEM.aaveV4Oracle().getReservePrice(2);
            collateralPrice = SYSTEM.aaveV4Oracle().getReservePrice(1);
            collateralDecimals = 6;
            debtDecimals = 18;
        }
        if (collateralPrice == 0) return 0;
        return Math.mulDiv(debtPrice * 10 ** collateralDecimals, 1e36, collateralPrice * 10 ** debtDecimals);
    }

    function _totalDebt(AgentWallet wallet) private view returns (uint256) {
        return _marketDebt(wallet, 0) + _marketDebt(wallet, 1) + _marketDebt(wallet, 2);
    }

    function _allDebtBalance() private view returns (uint256) {
        return _totalDebt(borrowWallets[0]) + _totalDebt(borrowWallets[1]);
    }

    function _supplyCall(uint8 index, uint256 amount) private view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(SYSTEM.aaveV3LendingAdapter().supplyCollateral, (SYSTEM.aaveV3Market(), amount));
        if (index == 1) return abi.encodeCall(SYSTEM.aaveV4LendingAdapter().supplyCollateral, (SYSTEM.aaveV4Market(), amount));
        return abi.encodeCall(SYSTEM.morphoBlueLendingAdapter().supplyCollateral, (SYSTEM.morphoMarket(), amount));
    }

    function _borrowCall(uint8 index, uint256 amount) private view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(SYSTEM.aaveV3LendingAdapter().borrow, (SYSTEM.aaveV3Market(), amount));
        if (index == 1) return abi.encodeCall(SYSTEM.aaveV4LendingAdapter().borrow, (SYSTEM.aaveV4Market(), amount));
        return abi.encodeCall(SYSTEM.morphoBlueLendingAdapter().borrow, (SYSTEM.morphoMarket(), amount));
    }

    function _repayCall(uint8 index, uint256 amount) private view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(SYSTEM.aaveV3LendingAdapter().repay, (SYSTEM.aaveV3Market(), amount));
        if (index == 1) return abi.encodeCall(SYSTEM.aaveV4LendingAdapter().repay, (SYSTEM.aaveV4Market(), amount));
        return abi.encodeCall(SYSTEM.morphoBlueLendingAdapter().repay, (SYSTEM.morphoMarket(), amount));
    }

    function _withdrawCollateralCall(uint8 index, uint256 amount) private view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(SYSTEM.aaveV3LendingAdapter().withdrawCollateral, (SYSTEM.aaveV3Market(), amount));
        if (index == 1) return abi.encodeCall(SYSTEM.aaveV4LendingAdapter().withdrawCollateral, (SYSTEM.aaveV4Market(), amount));
        return abi.encodeCall(SYSTEM.morphoBlueLendingAdapter().withdrawCollateral, (SYSTEM.morphoMarket(), amount));
    }

    function _checkpointCall(uint8 index) private view returns (bytes memory) {
        if (index == 0) return abi.encodeCall(SYSTEM.aaveV3LendingAdapter().checkpoint, (SYSTEM.aaveV3Market()));
        if (index == 1) return abi.encodeCall(SYSTEM.aaveV4LendingAdapter().checkpoint, (SYSTEM.aaveV4Market()));
        return abi.encodeCall(SYSTEM.morphoBlueLendingAdapter().checkpoint, (SYSTEM.morphoMarket()));
    }

    function _swapAdapter(uint8 dex) private view returns (address) {
        if (dex == 0) return address(SYSTEM.uniswapV3SwapAdapter());
        if (dex == 1) return address(SYSTEM.aerodromeV2SwapAdapter());
        return address(SYSTEM.aerodromeCLSwapAdapter());
    }

    function _swapRouter(uint8 dex) private view returns (address) {
        if (dex == 0) return address(SYSTEM.uniswapV3Router());
        if (dex == 1) return address(SYSTEM.aerodromeV2Router());
        return address(SYSTEM.aerodromeCLRouter());
    }

    function _setRouterBuyAmount(uint8 dex, uint256 amount) private {
        if (dex == 0) SYSTEM.uniswapV3Router().setBuyAmount(amount);
        else if (dex == 1) SYSTEM.aerodromeV2Router().setBuyAmount(amount);
        else SYSTEM.aerodromeCLRouter().setBuyAmount(amount);
    }

    function _ensureRouterLiquidity(uint8 dex, address token, uint256 amount) private {
        address router = _swapRouter(dex);
        uint256 balance = IERC20(token).balanceOf(router);
        if (balance < amount) {
            if (token == address(SYSTEM.usdc())) SYSTEM.usdc().mint(router, amount - balance);
            else SYSTEM.weth().mint(router, amount - balance);
        }
    }

    function _rewardRoute(uint8 dex, address sellToken, address buyToken) private pure returns (bytes memory) {
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory route;
            route.path = new address[](2);
            route.path[0] = sellToken;
            route.path[1] = buyToken;
            route.fees = new uint24[](1);
            route.fees[0] = 3_000;
            return abi.encode(route);
        }
        if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory route;
            route.path = new address[](2);
            route.path[0] = sellToken;
            route.path[1] = buyToken;
            route.stables = new bool[](1);
            route.stables[0] = false;
            return abi.encode(route);
        }
        AWKAerodromeCLSwapAdapter.SwapRoute memory clRoute;
        clRoute.path = new address[](2);
        clRoute.path[0] = sellToken;
        clRoute.path[1] = buyToken;
        clRoute.tickSpacings = new int24[](1);
        clRoute.tickSpacings[0] = 100;
        return abi.encode(clRoute);
    }

    function _borrowRoute(uint8 dex, address sellToken, address buyToken) private pure returns (bytes memory) {
        return _rewardRoute(dex, sellToken, buyToken);
    }

    function _rewardSwapCall(uint8 dex, bytes memory route, address sellToken, uint256 amount, uint256 deadline) private view returns (bytes memory) {
        if (dex == 0) return abi.encodeCall(SYSTEM.uniswapV3SwapAdapter().swap, (sellToken, address(SYSTEM.usdc()), abi.decode(route, (AWKUniswapV3SwapAdapter.SwapRoute)), amount, 1, deadline));
        if (dex == 1) return abi.encodeCall(SYSTEM.aerodromeV2SwapAdapter().swap, (sellToken, address(SYSTEM.usdc()), abi.decode(route, (AWKAerodromeV2SwapAdapter.SwapRoute)), amount, 1, deadline));
        return abi.encodeCall(SYSTEM.aerodromeCLSwapAdapter().swap, (sellToken, address(SYSTEM.usdc()), abi.decode(route, (AWKAerodromeCLSwapAdapter.SwapRoute)), amount, 1, deadline));
    }

    function _borrowSwapCall(uint8 dex, bytes memory route, uint256 amount) private view returns (bytes memory) {
        if (dex == 0) return abi.encodeCall(SYSTEM.uniswapV3SwapAdapter().swap, (address(SYSTEM.usdc()), address(SYSTEM.weth()), abi.decode(route, (AWKUniswapV3SwapAdapter.SwapRoute)), amount, 1, block.timestamp));
        if (dex == 1) return abi.encodeCall(SYSTEM.aerodromeV2SwapAdapter().swap, (address(SYSTEM.usdc()), address(SYSTEM.weth()), abi.decode(route, (AWKAerodromeV2SwapAdapter.SwapRoute)), amount, 1, block.timestamp));
        return abi.encodeCall(SYSTEM.aerodromeCLSwapAdapter().swap, (address(SYSTEM.usdc()), address(SYSTEM.weth()), abi.decode(route, (AWKAerodromeCLSwapAdapter.SwapRoute)), amount, 1, block.timestamp));
    }

    function _wallet(uint8 seed) private view returns (AgentWallet) {
        uint8 choice = seed % 4;
        if (choice == 0) return vaultWallets[0];
        if (choice == 1) return vaultWallets[1];
        if (choice == 2) return borrowWallets[0];
        return borrowWallets[1];
    }

    function _allWalletBaseBalance() private view returns (uint256 total) {
        for (uint256 i; i < 2; i++) {
            total += SYSTEM.usdc().balanceOf(address(vaultWallets[i])) + SYSTEM.usdc().balanceOf(address(borrowWallets[i]));
        }
    }

    function _allWalletWethBalance() private view returns (uint256 total) {
        for (uint256 i; i < 2; i++) {
            total += SYSTEM.weth().balanceOf(address(vaultWallets[i])) + SYSTEM.weth().balanceOf(address(borrowWallets[i]));
        }
    }

    function _allPositionValue() private view returns (uint256 total) {
        total = _allVaultPositionValue();
        for (uint256 i; i < 2; i++) {
            for (uint8 marketIndex; marketIndex < 3; marketIndex++) {
                total += _lendingCollateral(borrowWallets[i], marketIndex);
            }
        }
    }

    function _allVaultPositionValue() private view returns (uint256 total) {
        for (uint256 i; i < 2; i++) {
            for (uint8 vaultIndex; vaultIndex < 4; vaultIndex++) {
                total += _vaultPositionValue(vaultWallets[i], vaultIndex);
            }
        }
    }

    function _quoteWethToUsdc(uint256 amount) private view returns (uint256) {
        return SYSTEM.priceOracle().quote(address(SYSTEM.weth()), address(SYSTEM.usdc()), amount);
    }
}

contract PowerUserInvariantTest is StdInvariant, IntegrationBase {
    PowerUserHandler private handler;

    function setUp() public override {
        super.setUp();
        address ownerA = makeAddr("power user owner A");
        address ownerB = makeAddr("power user owner B");
        _fund(address(usdc), ownerA, 1_000_000e6);
        _fund(address(usdc), ownerB, 1_000_000e6);
        _fund(address(weth), ownerA, 100e18);
        _fund(address(weth), ownerB, 100e18);

        uint256 vaultPlan = vaultFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 2_000})));
        FeePlanChoice[] memory vaultPlans = new FeePlanChoice[](1);
        vaultPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: vaultPlan});
        uint256 borrowYieldPlan = borrowFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 2_000})));
        uint256 borrowPlan = borrowFeeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 100})));
        FeePlanChoice[] memory borrowPlans = new FeePlanChoice[](2);
        borrowPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: borrowYieldPlan});
        borrowPlans[1] = FeePlanChoice({feeType: BORROW_FEE, planId: borrowPlan});

        AgentWallet vaultA = _createVaultWallet(ownerA, 0);
        AgentWallet vaultB = _createVaultWallet(ownerB, 0, vaultPlans);
        AgentWallet borrowA = _createBorrowWallet(ownerA, 1);
        AgentWallet borrowB = _createBorrowWallet(ownerB, 1, borrowPlans);
        PowerUserDualRewards dualRewards = new PowerUserDualRewards(IERC20(address(wellToken)), IERC20(address(usdc)), 1e18, 1e6);
        borrowRegistry.registerAdapter(address(moonwellRewardAdapter));
        borrowRegistry.setTargetAdapter(address(dualRewards), address(moonwellRewardAdapter));
        vaultRegistry.setTargetAdapter(address(dualRewards), address(moonwellRewardAdapter));

        handler = new PowerUserHandler(
            PowerUserHandlerSetup({system: IntegrationBase(address(this)), ownerA: ownerA, ownerB: ownerB, operator: operator, vaultA: vaultA, vaultB: vaultB, borrowA: borrowA, borrowB: borrowB, dualRewards: dualRewards})
        );
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), address(handler));
        vaultRegistry.grantRole(vaultRegistry.DEFAULT_ADMIN_ROLE(), address(handler));
        vaultRegistry.grantRole(vaultRegistry.EMERGENCY_ROLE(), address(handler));
        borrowRegistry.grantRole(borrowRegistry.DEFAULT_ADMIN_ROLE(), address(handler));
        borrowRegistry.grantRole(borrowRegistry.EMERGENCY_ROLE(), address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](22);
        selectors[0] = PowerUserHandler.operatorDepositsVault.selector;
        selectors[1] = PowerUserHandler.operatorWithdrawsVault.selector;
        selectors[2] = PowerUserHandler.operatorChangesVaultValue.selector;
        selectors[3] = PowerUserHandler.ownerDonatesToVault.selector;
        selectors[4] = PowerUserHandler.operatorLendingWorkflow.selector;
        selectors[5] = PowerUserHandler.operatorAccruesLendingCollateral.selector;
        selectors[6] = PowerUserHandler.operatorWithdrawsCollateral.selector;
        selectors[7] = PowerUserHandler.operatorRepaysMarket.selector;
        selectors[8] = PowerUserHandler.operatorCheckpointsMarket.selector;
        selectors[9] = PowerUserHandler.protocolAccruesInterest.selector;
        selectors[10] = PowerUserHandler.operatorClaimsMerklAndSells.selector;
        selectors[11] = PowerUserHandler.operatorClaimsMoonwellAndSells.selector;
        selectors[12] = PowerUserHandler.operatorRunsBorrowSwapAndRepays.selector;
        selectors[13] = PowerUserHandler.operatorMovesBetweenWallets.selector;
        selectors[14] = PowerUserHandler.ownerWithdrawsOneAsset.selector;
        selectors[15] = PowerUserHandler.ownerWithdrawsAllBase.selector;
        selectors[16] = PowerUserHandler.ownerWithdrawsBatch.selector;
        selectors[17] = PowerUserHandler.ownerWithdrawsEth.selector;
        selectors[18] = PowerUserHandler.ownerBlocksOrUnblocks.selector;
        selectors[19] = PowerUserHandler.adminChangesRegistryThenSyncs.selector;
        selectors[20] = PowerUserHandler.timePasses.selector;
        selectors[21] = PowerUserHandler.marketPricesMove.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // NOTE(krishan711): each handler call runs a whole workflow across several adapters, so 400 deep runs (80,000 calls) keep the deep profile near five minutes.
    /// forge-config: deep.invariant.runs = 400
    function invariant_powerUserPositionsAndFeeLedgersMatchWalletActivity() public view {
        handler.assertPositionAccounting();
        handler.assertFeeAccounting();
    }

    /// forge-config: deep.invariant.runs = 400
    function invariant_powerUserValueAndWithdrawableBalanceStayWithinAllowedCosts() public view {
        handler.assertOwnerValueBound();
        handler.assertWithdrawableBalances();
    }

    function test_powerUserRunsEveryAdapterThenClosesOutCleanly() public {
        handler.runRepresentativeWorkflows();
        handler.assertEveryWorkflowWasCalled();
        handler.logWorkflowCalls();
        handler.assertPositionAccounting();
        handler.assertFeeAccounting();
        handler.assertWithdrawableBalances();
        handler.assertOwnerValueBound();
        uint256 snapshot = vm.snapshotState();
        handler.closeOutAll();
        vm.revertToState(snapshot);
    }

    // NOTE(krishan711): a full close-out after every one of 200,000 calls dominated the deep run, so it runs at the end of each random sequence instead.
    function afterInvariant() public {
        uint256 snapshot = vm.snapshotState();
        handler.closeOutAll();
        vm.revertToState(snapshot);
        handler.logWorkflowCalls();
    }
}

contract PowerUserLifecycleFuzzTest is IntegrationBase {
    uint256 private constant YEAR = 365 days;

    function testFuzz_vaultOwnerLifecycleFromFirstDepositToFullExit(uint256 amountSeed, uint256 yieldSeed, uint256 timeSeed, uint256 priceSeed) public {
        address vaultOwner = makeAddr("vault lifecycle owner");
        AgentWallet wallet = _createVaultWallet(vaultOwner, 0);
        uint256[4] memory principal;
        uint256[4] memory expectedOut;
        for (uint8 i; i < 4; i++) {
            principal[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 10e6, 1_000e6);
            usdc.mint(vaultOwner, principal[i]);
            vm.prank(vaultOwner);
            usdc.transfer(address(wallet), principal[i]);
            _execute(wallet, _vaultAdapter(i), _vaultTarget(i), abi.encodeWithSignature("deposit(uint256)", principal[i]));
        }

        uint256 yieldBps = bound(yieldSeed, 1, 1_000);
        uint256 totalFee;
        for (uint8 i; i < 4; i++) {
            if (i == 0) {
                uint256 gain = Math.mulDiv(principal[i], yieldBps, 10_000);
                usdc.mint(address(erc4626Vault), gain);
                expectedOut[i] = erc4626Vault.convertToAssets(erc4626Vault.balanceOf(address(wallet)));
            } else if (i == 1) {
                uint256 gain = Math.mulDiv(principal[i], yieldBps, 10_000);
                aaveV3Vault.addYield(address(wallet), gain);
                usdc.mint(address(aaveV3Vault), gain);
                expectedOut[i] = aaveV3Vault.balanceOf(address(wallet));
            } else if (i == 2) {
                MockCToken market = compoundV2Vault;
                uint256 oldRate = market.exchangeRateCurrent();
                uint256 shares = market.balanceOf(address(wallet));
                uint256 nextRate = oldRate * (10_000 + yieldBps) / 10_000;
                expectedOut[i] = Math.mulDiv(shares, nextRate, 1e18);
                uint256 needed = expectedOut[i] > principal[i] ? expectedOut[i] - principal[i] : 0;
                usdc.mint(address(market), needed + 2);
                market.addYield(yieldBps);
            } else {
                uint256 gain = Math.mulDiv(principal[i], yieldBps, 10_000);
                compoundV3Market.addYield(address(wallet), gain);
                usdc.mint(address(compoundV3Market), gain);
                expectedOut[i] = compoundV3Market.balanceOf(address(wallet));
            }
        }
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + bound(timeSeed, 30 days, 300 days));
        uint256 price = bound(priceSeed, 1_000e8, 3_000e8);
        uint256 now_ = vm.getBlockTimestamp();
        wethPriceFeed.setPrice(int256(price), now_);
        usdcPriceFeed.setPrice(1e8, now_);
        aaveV3LendingPool.setAssetPrice(address(weth), price);
        aaveV4Spoke.setReservePrice(2, price);

        uint256 expectedGross;
        for (uint8 i; i < 4; i++) {
            uint256 output = expectedOut[i];
            if (output > principal[i]) totalFee += Math.mulDiv(output - principal[i], YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
            expectedGross += output;
            bytes memory result = _execute(wallet, _vaultAdapter(i), _vaultTarget(i), abi.encodeWithSignature("withdraw(uint256)", IERC20(_vaultTarget(i)).balanceOf(address(wallet))));
            uint256 actualOutput = abi.decode(abi.decode(result, (bytes)), (uint256));
            assertEq(actualOutput, output);
        }
        vm.prank(vaultOwner);
        wallet.withdrawAllAssetToUser(vaultOwner, address(usdc));
        assertEq(usdc.balanceOf(vaultOwner), expectedGross - totalFee);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), totalFee);
        for (uint8 i; i < 4; i++) {
            assertEq(IERC20(_vaultTarget(i)).balanceOf(address(wallet)), 0);
            assertEq(vaultYieldFeeModule.costBasis(address(wallet), _vaultTarget(i)), 0);
        }
        assertLe(totalFee, expectedGross);
    }

    function testFuzz_borrowOwnerLifecycleFromFirstDepositToFullExit(uint256 collateralSeed, uint256 debtSeed, uint256 timeSeed, uint256 priceSeed) public {
        address borrowOwner = makeAddr("borrow lifecycle owner");
        AgentWallet wallet = _createBorrowWallet(borrowOwner, 0);
        uint256 collateralTotal = bound(collateralSeed, 3_000e6, 30_000e6) / 3 * 3;
        uint256 collateralEach = collateralTotal / 3;
        uint256 debtAmount = bound(debtSeed, 1e15, 1e17);
        usdc.mint(borrowOwner, collateralTotal);
        vm.prank(borrowOwner);
        usdc.transfer(address(wallet), collateralTotal);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralEach)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.supplyCollateral, (aaveV4Market, collateralEach)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.supplyCollateral, (morphoMarket, collateralEach)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, debtAmount)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.borrow, (aaveV4Market, debtAmount)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.borrow, (morphoMarket, debtAmount)));

        uint256 start = vm.getBlockTimestamp();
        uint256 firstPeriod = bound(timeSeed, 30 days, 180 days);
        uint256 secondPeriod = bound(timeSeed >> 32, 30 days, 180 days);
        uint256 nextPrice = bound(priceSeed, 1_000e8, 3_000e8);
        vm.warp(start + firstPeriod);
        uint256 now_ = vm.getBlockTimestamp();
        usdcPriceFeed.setPrice(1e8, now_);
        wethPriceFeed.setPrice(int256(nextPrice), now_);
        aaveV3LendingPool.setAssetPrice(address(weth), nextPrice);
        aaveV4Spoke.setReservePrice(2, nextPrice);
        morphoOracle.setPrice(1e56 / nextPrice);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.checkpoint, (aaveV4Market)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.checkpoint, (morphoMarket)));

        vm.warp(vm.getBlockTimestamp() + secondPeriod);
        uint256 secondNow = vm.getBlockTimestamp();
        usdcPriceFeed.setPrice(1e8, secondNow);
        wethPriceFeed.setPrice(int256(nextPrice), secondNow);
        uint256 expectedFee = _expectedBorrowFee(debtAmount, BORROW_FEE_BPS, firstPeriod, nextPrice) * 3;
        expectedFee += _expectedBorrowFee(debtAmount, BORROW_FEE_BPS, secondPeriod, nextPrice) * 3;
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.checkpoint, (aaveV4Market)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.checkpoint, (morphoMarket)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedFee);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.repay, (aaveV4Market, type(uint256).max)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.repay, (morphoMarket, type(uint256).max)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, type(uint256).max)));
        _execute(wallet, address(morphoBlueLendingAdapter), morphoBlueLendingAdapter.marketTarget(morphoMarket), abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        vm.prank(borrowOwner);
        wallet.withdrawAllAssetToUser(borrowOwner, address(usdc));
        assertEq(usdc.balanceOf(borrowOwner), collateralTotal - expectedFee);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), 0);
        (, IMorphoBlue.MarketParams memory params) = abi.decode(morphoMarket, (address, IMorphoBlue.MarketParams));
        (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = morpho.position(keccak256(abi.encode(params)), address(wallet));
        assertEq(supplyShares, 0);
        assertEq(borrowShares, 0);
        assertEq(collateral, 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), expectedFee);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertGt(vm.getBlockTimestamp(), start + firstPeriod);
    }

    function _vaultAdapter(uint8 index) private view returns (address) {
        if (index == 0) return address(erc4626Adapter);
        if (index == 1) return address(aaveV3Adapter);
        if (index == 2) return address(compoundV2Adapter);
        return address(compoundV3Adapter);
    }

    function _vaultTarget(uint8 index) private view returns (address) {
        if (index == 0) return address(erc4626Vault);
        if (index == 1) return address(aaveV3Vault);
        if (index == 2) return address(compoundV2Vault);
        return address(compoundV3Market);
    }

    function _expectedBorrowFee(uint256 debt, uint256 rate, uint256 elapsed, uint256 price) private pure returns (uint256) {
        uint256 debtFee = Math.mulDiv(debt, rate * elapsed, YEAR * 10_000, Math.Rounding.Ceil);
        return Math.mulDiv(debtFee, price * 1e16, 1e36, Math.Rounding.Ceil);
    }
}
