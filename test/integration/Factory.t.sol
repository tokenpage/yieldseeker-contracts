pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as RealFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {SellTokenNotAllowed, YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {AgentAlreadyExists, InvalidImplementationFactory, NoAgentWalletImplementationSet, TooManyOperators, UnknownAgentProfile} from "../../src/agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, UnknownPlan, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {IYieldSeekerSwapPolicy} from "../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {YieldSeekerVaultSwapPolicy} from "../../src/swaps/VaultSwapPolicy.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract FactoryTest is IntegrationBase {
    event FeeTrackerUpdated(bytes32 indexed agentProfile, address indexed oldFeeTracker, address indexed newFeeTracker);
    event SwapPolicyUpdated(bytes32 indexed agentProfile, address indexed oldSwapPolicy, address indexed newSwapPolicy);

    function testBorrowWalletUsesProfileFeeTrackerForDebtAccounting() public {
        uint256 selectedPlan = borrowFeeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 25})));
        FeePlanChoice[] memory borrowPlans = new FeePlanChoice[](1);
        borrowPlans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: selectedPlan});
        AgentWallet borrowWallet = _createBorrowWallet(owner, 21, borrowPlans);
        uint256 collateralAmount = 100e6;
        uint256 borrowedAmount = 1e18;

        _fundWallet(borrowWallet, address(usdc), collateralAmount);
        bytes memory supplyData = abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount));
        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), supplyData);
        bytes memory borrowData = abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowedAmount));
        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), borrowData);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bytes memory repayData = abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max));
        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), repayData);

        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 5e6);
        assertTrue(borrowFeeTracker.isAccountedToken(address(borrowWallet), address(weth)));
    }

    function testWalletAddressesAreDeterministicAndOwnerIndexCannotBeReused() public {
        address predicted = factory.getAddress(owner, 30);
        assertTrue(factory.getAddress(owner, 31) != predicted);
        assertTrue(factory.getAddress(makeAddr("anotherOwner"), 30) != predicted);

        AgentWallet wallet = _createVaultWallet(owner, 30);
        assertEq(address(wallet), predicted);

        bytes memory expectedError = abi.encodeWithSelector(AgentAlreadyExists.selector, owner, 30);
        vm.expectRevert(expectedError);
        vm.prank(operator);
        factory.createAgentWallet(owner, 30, address(usdc), BORROW_AGENT_PROFILE, new FeePlanChoice[](0));
    }

    function testOperatorLimitIncludesConstructorOperatorAndAllowsRegrantAtLimit() public {
        bytes32 role = factory.AGENT_OPERATOR_ROLE();
        assertEq(factory.getRoleMemberCount(role), 1);
        assertEq(factory.MAX_OPERATORS(), 10);

        for (uint256 i = 0; i < 9; i++) {
            factory.grantRole(role, address(uint160(1000 + i)));
        }
        assertEq(factory.getRoleMemberCount(role), factory.MAX_OPERATORS());

        factory.grantRole(role, operator);
        assertEq(factory.getRoleMemberCount(role), factory.MAX_OPERATORS());

        address extraOperator = address(2000);
        vm.expectRevert(TooManyOperators.selector);
        factory.grantRole(role, extraOperator);
        assertFalse(factory.hasRole(role, extraOperator));
        assertEq(factory.getRoleMemberCount(role), factory.MAX_OPERATORS());
    }

    function testImplementationMustBeAContractBoundToThisFactory() public {
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        factory.setAgentWalletImplementation(AgentWallet(payable(address(0))));

        address notAContract = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, notAContract));
        factory.setAgentWalletImplementation(AgentWallet(payable(notAContract)));

        RealFactory otherFactory = new RealFactory(admin, admin, operator);
        AgentWallet foreignImplementation = new AgentWallet(address(otherFactory));
        vm.expectRevert(InvalidImplementationFactory.selector);
        factory.setAgentWalletImplementation(foreignImplementation);
        assertEq(address(factory.agentWalletImplementation()), address(walletImplementation));
    }

    function testWalletCreationRequiresImplementation() public {
        RealFactory emptyFactory = new RealFactory(admin, admin, operator);
        vm.expectRevert(NoAgentWalletImplementationSet.selector);
        vm.prank(operator);
        emptyFactory.createAgentWallet(owner, 1, address(usdc), VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
    }

    function testFactoryProfileConfigurationValidatesAccessAndEmitsEvents() public {
        address stranger = makeAddr("factoryConfigurationStranger");
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, adminRole);
        FeeTracker nextTracker = new FeeTracker(admin, feeCollector);
        YieldSeekerVaultSwapPolicy nextPolicy = new YieldSeekerVaultSwapPolicy(swapSellPolicy);
        address notAContract = address(0x1234);
        bytes memory nonContractError = abi.encodeWithSelector(AWKErrors.NotAContract.selector, notAContract);
        bytes memory zeroProfileError = abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(0));
        bytes memory zeroTrackerError = abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0));

        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, nextTracker);
        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, nextPolicy);

        vm.expectRevert(zeroProfileError);
        factory.setFeeTracker(bytes32(0), nextTracker);
        vm.expectRevert(zeroProfileError);
        factory.setSwapPolicy(bytes32(0), nextPolicy);
        vm.expectRevert(zeroProfileError);
        factory.setAdapterRegistry(bytes32(0), vaultRegistry);

        vm.expectRevert(nonContractError);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, FeeTracker(notAContract));
        vm.expectRevert(nonContractError);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, IYieldSeekerSwapPolicy(notAContract));
        vm.expectRevert(zeroTrackerError);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, FeeTracker(address(0)));

        address previousTracker = address(factory.feeTracker(VAULT_AGENT_PROFILE));
        vm.expectEmit(true, true, true, true, address(factory));
        emit FeeTrackerUpdated(VAULT_AGENT_PROFILE, previousTracker, address(nextTracker));
        factory.setFeeTracker(VAULT_AGENT_PROFILE, nextTracker);

        address previousPolicy = address(factory.swapPolicy(VAULT_AGENT_PROFILE));
        vm.expectEmit(true, true, true, true, address(factory));
        emit SwapPolicyUpdated(VAULT_AGENT_PROFILE, previousPolicy, address(nextPolicy));
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, nextPolicy);
    }

    function testWalletSyncRefreshesOnlyItsProfileConfiguration() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 40);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 41);
        MockERC4626 nextVault = new MockERC4626(address(usdc), "Synced Vault", "svUSDC");
        AdapterRegistry nextVaultRegistry = new AdapterRegistry(admin, admin);
        _registerTarget(nextVaultRegistry, address(nextVault), address(erc4626Adapter));
        _registerTarget(nextVaultRegistry, address(uniswapV3Router), address(uniswapV3SwapAdapter));

        FeeTracker nextVaultTracker = new FeeTracker(admin, feeCollector);
        YieldSeekerYieldFeeModule nextVaultYieldModule = new YieldSeekerYieldFeeModule(nextVaultTracker, 5000);
        nextVaultTracker.setFeeModule(YIELD_FEE, nextVaultYieldModule);
        nextVaultTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_FEE_BPS})));
        nextVaultTracker.setWalletFactory(address(factory));

        SwapSellPolicy nextSellPolicy = new SwapSellPolicy(admin, admin, false);
        nextSellPolicy.addSellableToken(address(rewardToken));
        YieldSeekerVaultSwapPolicy nextVaultPolicy = new YieldSeekerVaultSwapPolicy(nextSellPolicy);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, nextVaultRegistry);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, nextVaultTracker);
        factory.setSwapPolicy(VAULT_AGENT_PROFILE, nextVaultPolicy);

        bytes memory depositData = abi.encodeCall(erc4626Adapter.deposit, (uint256(100e6)));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(erc4626Adapter)));
        vm.prank(operator);
        vaultWallet.executeViaAdapter(address(erc4626Adapter), address(nextVault), depositData);

        vm.prank(operator);
        vaultWallet.syncFromFactory();

        uint256 depositAmount = 100e6;
        uint256 yieldAmount = 10e6;
        _fundWallet(vaultWallet, address(usdc), depositAmount);
        _execute(vaultWallet, address(erc4626Adapter), address(nextVault), depositData);
        uint256 shares = nextVault.balanceOf(address(vaultWallet));
        _fund(address(usdc), address(nextVault), yieldAmount);
        uint256 feesBefore = _feesCollected(address(usdc));
        bytes memory withdrawData = abi.encodeCall(erc4626Adapter.withdraw, (shares));
        _execute(vaultWallet, address(erc4626Adapter), address(nextVault), withdrawData);

        uint256 expectedYieldFee = yieldAmount * YIELD_FEE_BPS / 10_000;
        assertEq(_feesCollected(address(usdc)) - feesBefore, expectedYieldFee);
        assertEq(nextVaultYieldModule.feesOwed(address(vaultWallet)), 0);
        assertEq(vaultYieldFeeModule.feesOwed(address(vaultWallet)), 0);

        address stranger = makeAddr("syncWithdrawalStranger");
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        vaultWallet.withdrawAllAssetToUser(owner, address(usdc));
        vm.prank(owner);
        vaultWallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), depositAmount + yieldAmount - expectedYieldFee);

        AWKUniswapV3SwapAdapter.SwapRoute memory wellToUsdc;
        wellToUsdc.path = new address[](2);
        wellToUsdc.path[0] = address(wellToken);
        wellToUsdc.path[1] = address(usdc);
        wellToUsdc.fees = new uint24[](1);
        wellToUsdc.fees[0] = 3000;
        bytes memory swapData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(wellToken), address(usdc), wellToUsdc, uint256(10e18), uint256(1)));
        bytes memory sellBlocked = abi.encodeWithSelector(SellTokenNotAllowed.selector, address(wellToken));
        _executeExpectRevert(vaultWallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), swapData, sellBlocked);

        _fundWallet(borrowWallet, address(wellToken), 10e18);
        uniswapV3Router.setBuyAmount(10e6);
        feesBefore = _feesCollected(address(usdc));
        _execute(borrowWallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), swapData);
        assertEq(usdc.balanceOf(address(borrowWallet)), 9e6);
        assertEq(_feesCollected(address(usdc)) - feesBefore, 1e6);
    }

    function testWalletCreationRejectsUnknownProfileAndNonOperator() public {
        bytes32 unknownProfile = keccak256("missing-agent-profile");
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, unknownProfile));
        vm.prank(operator);
        factory.createAgentWallet(owner, 50, address(usdc), unknownProfile, new FeePlanChoice[](0));

        address stranger = makeAddr("creationStranger");
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, factory.AGENT_OPERATOR_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(stranger);
        factory.createAgentWallet(owner, 50, address(usdc), VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
    }

    function testFeePlanSelectionValidatesPlanAndTrackerFactory() public {
        FeePlanChoice[] memory choices = new FeePlanChoice[](1);
        choices[0] = FeePlanChoice({feeType: BORROW_FEE, planId: 1});
        vm.expectRevert(abi.encodeWithSelector(UnknownPlan.selector, BORROW_FEE, 1));
        vm.prank(operator);
        factory.createAgentWallet(owner, 60, address(usdc), BORROW_AGENT_PROFILE, choices);

        borrowFeeTracker.setWalletFactory(address(borrowFeeModule));
        choices[0] = FeePlanChoice({feeType: BORROW_FEE, planId: 0});
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, address(factory)));
        vm.prank(operator);
        factory.createAgentWallet(owner, 61, address(usdc), BORROW_AGENT_PROFILE, choices);
    }

    function testWalletCreationRejectsZeroOwnerAndInvalidBaseAsset() public {
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(operator);
        factory.createAgentWallet(address(0), 70, address(usdc), VAULT_AGENT_PROFILE, noFeePlans);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(operator);
        factory.createAgentWallet(owner, 70, address(0), VAULT_AGENT_PROFILE, noFeePlans);

        address notAContract = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, notAContract));
        vm.prank(operator);
        factory.createAgentWallet(owner, 70, notAContract, VAULT_AGENT_PROFILE, noFeePlans);
    }
}
