// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerAgentTransferAdapter as AgentTransferAdapter} from "../../../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockERC20, MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockUniswapV3Router} from "../../mocks/MockIntegrationMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

struct WalletHandlerSetup {
    address owner;
    address otherOwner;
    address operator;
    address attacker;
    address feeCollector;
    AgentWallet ownerAgent;
    AgentWallet ownerSecondAgent;
    AgentWallet otherOwnerAgent;
    AgentWalletFactory factory;
    AdapterRegistry vaultRegistry;
    AdapterRegistry borrowRegistry;
    MockERC20 usdc;
    MockERC20WithDecimals rewardToken;
    MockERC4626 vault;
    ERC4626Adapter vaultAdapter;
    UniswapV3SwapAdapter swapAdapter;
    AgentTransferAdapter transferAdapter;
    MockUniswapV3Router router;
}

contract WalletWorkflowHandler is Test {
    AgentWallet public immutable ownerAgent;
    AgentWallet public immutable ownerSecondAgent;
    AgentWallet public immutable otherOwnerAgent;
    AgentWalletFactory public immutable factory;
    AdapterRegistry public immutable vaultRegistry;
    AdapterRegistry public immutable borrowRegistry;
    MockERC20 public immutable usdc;
    MockERC20WithDecimals public immutable rewardToken;
    MockERC4626 public immutable vault;
    ERC4626Adapter public immutable vaultAdapter;
    UniswapV3SwapAdapter public immutable swapAdapter;
    AgentTransferAdapter public immutable transferAdapter;
    MockUniswapV3Router public immutable router;
    address public immutable owner;
    address public immutable otherOwner;
    address public immutable operator;
    address public immutable attacker;
    address public immutable feeCollector;

    uint256 public immutable attackerStartingUsdc;
    uint256 public attackerDonatedUsdc;
    bool public attackerReceivedWalletTokens;
    bool public attackerPrivilegeSucceeded;
    uint256 public depositCalls;
    uint256 public vaultCalls;
    uint256 public swapCalls;
    uint256 public ownerWithdrawalCalls;
    uint256 public otherOwnerWithdrawalCalls;
    uint256 public blocklistCalls;
    uint256 public transferCalls;
    uint256 public attackCalls;
    uint256 public donationCalls;
    uint256 public emergencyCalls;
    uint256 public operatorSyncCalls;

    constructor(WalletHandlerSetup memory setup) {
        owner = setup.owner;
        otherOwner = setup.otherOwner;
        operator = setup.operator;
        attacker = setup.attacker;
        feeCollector = setup.feeCollector;
        ownerAgent = setup.ownerAgent;
        ownerSecondAgent = setup.ownerSecondAgent;
        otherOwnerAgent = setup.otherOwnerAgent;
        factory = setup.factory;
        vaultRegistry = setup.vaultRegistry;
        borrowRegistry = setup.borrowRegistry;
        usdc = setup.usdc;
        rewardToken = setup.rewardToken;
        vault = setup.vault;
        vaultAdapter = setup.vaultAdapter;
        swapAdapter = setup.swapAdapter;
        transferAdapter = setup.transferAdapter;
        router = setup.router;

        attackerStartingUsdc = 1_000e6;
        usdc.mint(owner, 500_000e6);
        usdc.mint(otherOwner, 500_000e6);
        usdc.mint(attacker, attackerStartingUsdc);
    }

    function userDeposits(uint96 amountSeed, bool depositForOtherOwner) external {
        address depositor = depositForOtherOwner ? otherOwner : owner;
        AgentWallet recipientWallet = depositForOtherOwner ? otherOwnerAgent : ownerAgent;
        uint256 available = usdc.balanceOf(depositor);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(depositor);
        if (usdc.transfer(address(recipientWallet), amount)) depositCalls++;
    }

    function operatorRunsVault(uint96 amountSeed, uint96 yieldSeed) external {
        vaultCalls++;
        uint256 available = usdc.balanceOf(address(ownerAgent));
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        uint256 sharesBefore = vault.balanceOf(address(ownerAgent));
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (amount));
        if (!_operatorExecute(ownerAgent, address(vaultAdapter), address(vault), depositData)) return;
        uint256 shares = vault.balanceOf(address(ownerAgent)) - sharesBefore;
        if (shares == 0) return;

        uint256 yieldAmount = bound(yieldSeed, 0, 10e6);
        if (yieldAmount > 0) usdc.mint(address(vault), yieldAmount);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));
        _operatorExecute(ownerAgent, address(vaultAdapter), address(vault), withdrawData);
    }

    function operatorSellsEarnedRewards(uint96 amountSeed) external {
        swapCalls++;
        uint256 amount = bound(amountSeed, 1e18, 5e18);
        rewardToken.mint(address(ownerAgent), amount);
        router.setBuyAmount(1e6);

        AWKUniswapV3SwapAdapter.SwapRoute memory route;
        route.path = new address[](2);
        route.path[0] = address(rewardToken);
        route.path[1] = address(usdc);
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
        bytes memory data = abi.encodeCall(swapAdapter.swap, (address(rewardToken), address(usdc), route, amount, uint256(1e6), block.timestamp));
        _operatorExecute(ownerAgent, address(swapAdapter), address(router), data);
    }

    function ownerWithdrawsEverything(bool useSecondAgent) external {
        AgentWallet wallet = useSecondAgent ? ownerSecondAgent : ownerAgent;
        bytes memory data = abi.encodeCall(wallet.withdrawAllAssetToUser, (owner, address(usdc)));
        vm.prank(owner);
        (bool success,) = address(wallet).call(data);
        if (success) ownerWithdrawalCalls++;
    }

    function otherOwnerWithdrawsEverything() external {
        bytes memory data = abi.encodeCall(otherOwnerAgent.withdrawAllAssetToUser, (otherOwner, address(usdc)));
        vm.prank(otherOwner);
        (bool success,) = address(otherOwnerAgent).call(data);
        if (success) otherOwnerWithdrawalCalls++;
    }

    function ownerBlocksAdapter(bool blockSwapAdapter, bool blockIt) external {
        blocklistCalls++;
        address adapter = blockSwapAdapter ? address(swapAdapter) : address(vaultAdapter);
        vm.prank(owner);
        if (blockIt) ownerAgent.blockAdapter(adapter);
        else ownerAgent.unblockAdapter(adapter);
    }

    function ownerBlocksTarget(bool blockSwapTarget, bool blockIt) external {
        blocklistCalls++;
        address target = blockSwapTarget ? address(router) : address(vault);
        vm.prank(owner);
        if (blockIt) ownerAgent.blockTarget(target);
        else ownerAgent.unblockTarget(target);
    }

    function operatorMovesFundsBetweenAgents(uint96 amountSeed, bool moveForward) external {
        transferCalls++;
        AgentWallet sender = moveForward ? ownerAgent : ownerSecondAgent;
        AgentWallet receiver = moveForward ? ownerSecondAgent : ownerAgent;
        uint256 balance = usdc.balanceOf(address(sender));
        if (balance < 2) return;
        uint256 amount = bound(amountSeed, 1, balance / 2);
        bytes memory data = abi.encodeCall(transferAdapter.transfer, (address(usdc), address(receiver), amount));
        _operatorExecute(sender, address(transferAdapter), address(transferAdapter), data);
    }

    function attackerTriesEveryPrivilegedCall(uint8 walletChoice, uint96 amountSeed) external {
        attackCalls++;
        AgentWallet wallet = _walletFor(walletChoice);
        bytes[] memory calls = new bytes[](18);
        calls[0] = abi.encodeCall(wallet.blockAdapter, (address(vaultAdapter)));
        calls[1] = abi.encodeCall(wallet.unblockAdapter, (address(vaultAdapter)));
        calls[2] = abi.encodeCall(wallet.blockTarget, (address(vault)));
        calls[3] = abi.encodeCall(wallet.unblockTarget, (address(vault)));
        calls[4] = abi.encodeCall(wallet.upgradeToLatest, ());
        calls[5] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(factory.agentWalletImplementation()), bytes(""));
        calls[6] = abi.encodeCall(wallet.withdrawAssetToUser, (attacker, address(usdc), 1));
        calls[7] = abi.encodeCall(wallet.withdrawAllAssetToUser, (attacker, address(usdc)));
        calls[8] = abi.encodeCall(wallet.withdrawAssetsToUser, (attacker, new address[](0), new uint256[](0)));
        calls[9] = abi.encodeCall(wallet.withdrawAllAssetsToUser, (attacker, new address[](0)));
        calls[10] = abi.encodeCall(wallet.withdrawEthToUser, (attacker, 1));
        calls[11] = abi.encodeCall(wallet.withdrawAllEthToUser, (attacker));
        calls[12] = abi.encodeCall(wallet.executeViaAdapter, (address(transferAdapter), address(transferAdapter), bytes("")));
        calls[13] = abi.encodeCall(wallet.executeViaAdapterBatch, (new address[](0), new address[](0), new bytes[](0)));
        calls[14] = abi.encodeWithSignature("execute(address,uint256,bytes)", address(usdc), 0, bytes(""));
        calls[15] = abi.encodeWithSignature("executeBatch(address[],bytes[])", new address[](0), new bytes[](0));
        calls[16] = abi.encodeCall(wallet.settleFeesForWithdrawal, (address(usdc), attacker, 1));
        calls[17] = abi.encodeWithSignature("initialize(address,uint256,address,bytes32)", owner, wallet.ownerAgentIndex(), address(usdc), wallet.agentProfile());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(attacker);
            (bool success,) = address(wallet).call(calls[i]);
            if (success) attackerPrivilegeSucceeded = true;
        }

        uint256 amount = amountSeed;
        uint256 walletBalance = usdc.balanceOf(address(wallet));
        if (walletBalance > 0) {
            amount = amount == 0 ? 1 : bound(amount, 1, walletBalance);
            vm.prank(attacker);
            (bool pulled,) = address(usdc).call(abi.encodeCall(usdc.transferFrom, (address(wallet), attacker, amount)));
            if (pulled) attackerReceivedWalletTokens = true;
        }
    }

    function attackerDonatesTokensToWallet(uint96 amountSeed, uint8 walletChoice) external {
        donationCalls++;
        uint256 balance = usdc.balanceOf(attacker);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        AgentWallet recipient = _walletFor(walletChoice);
        vm.prank(attacker);
        if (usdc.transfer(address(recipient), amount)) attackerDonatedUsdc += amount;
    }

    function emergencyPausesOrUnpausesRegistry(bool pauseRegistry) external {
        emergencyCalls++;
        if (pauseRegistry && !vaultRegistry.paused()) vaultRegistry.pause();
        if (!pauseRegistry && vaultRegistry.paused()) vaultRegistry.unpause();
    }

    function factoryOperatorChangesThenSyncs(bool restoreOperator) external {
        operatorSyncCalls++;
        bytes32 role = factory.AGENT_OPERATOR_ROLE();
        bool hasOperator = factory.hasRole(role, operator);
        if (restoreOperator && !hasOperator) factory.grantRole(role, operator);
        if (!restoreOperator && hasOperator) factory.removeAgentOperator(operator);
        _syncAllWallets();
    }

    function _operatorExecute(AgentWallet wallet, address adapter, address target, bytes memory data) private returns (bool success) {
        vm.prank(operator);
        (success,) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapter, (adapter, target, data)));
    }

    function _walletFor(uint8 choice) private view returns (AgentWallet) {
        uint8 selected = choice % 3;
        if (selected == 0) return ownerAgent;
        if (selected == 1) return ownerSecondAgent;
        return otherOwnerAgent;
    }

    function _syncAllWallets() private {
        ownerAgent.syncFromFactory();
        ownerSecondAgent.syncFromFactory();
        otherOwnerAgent.syncFromFactory();
    }
}

contract WalletInvariantTest is IntegrationBase {
    WalletWorkflowHandler private handler;
    AgentWallet private ownerAgent;
    AgentWallet private ownerSecondAgent;
    AgentWallet private otherOwnerAgent;
    address private otherOwner;
    address private attacker;

    function setUp() public override {
        super.setUp();
        otherOwner = makeAddr("otherOwner");
        attacker = makeAddr("attacker");
        ownerAgent = _createVaultWallet(owner, 1);
        ownerSecondAgent = _createVaultWallet(owner, 2);
        otherOwnerAgent = _createVaultWallet(otherOwner, 1);
        handler = new WalletWorkflowHandler(
            WalletHandlerSetup({
                owner: owner,
                otherOwner: otherOwner,
                operator: operator,
                attacker: attacker,
                feeCollector: feeCollector,
                ownerAgent: ownerAgent,
                ownerSecondAgent: ownerSecondAgent,
                otherOwnerAgent: otherOwnerAgent,
                factory: factory,
                vaultRegistry: vaultRegistry,
                borrowRegistry: borrowRegistry,
                usdc: usdc,
                rewardToken: rewardToken,
                vault: erc4626Vault,
                vaultAdapter: erc4626Adapter,
                swapAdapter: uniswapV3SwapAdapter,
                transferAdapter: agentTransferAdapter,
                router: uniswapV3Router
            })
        );
        factory.grantRole(factory.DEFAULT_ADMIN_ROLE(), address(handler));
        factory.grantRole(factory.EMERGENCY_ROLE(), address(handler));
        vaultRegistry.grantRole(vaultRegistry.DEFAULT_ADMIN_ROLE(), address(handler));
        vaultRegistry.grantRole(vaultRegistry.EMERGENCY_ROLE(), address(handler));

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = WalletWorkflowHandler.userDeposits.selector;
        selectors[1] = WalletWorkflowHandler.operatorRunsVault.selector;
        selectors[2] = WalletWorkflowHandler.operatorSellsEarnedRewards.selector;
        selectors[3] = WalletWorkflowHandler.ownerWithdrawsEverything.selector;
        selectors[4] = WalletWorkflowHandler.otherOwnerWithdrawsEverything.selector;
        selectors[5] = WalletWorkflowHandler.ownerBlocksAdapter.selector;
        selectors[6] = WalletWorkflowHandler.ownerBlocksTarget.selector;
        selectors[7] = WalletWorkflowHandler.operatorMovesFundsBetweenAgents.selector;
        selectors[8] = WalletWorkflowHandler.attackerTriesEveryPrivilegedCall.selector;
        selectors[9] = WalletWorkflowHandler.attackerDonatesTokensToWallet.selector;
        selectors[10] = WalletWorkflowHandler.emergencyPausesOrUnpausesRegistry.selector;
        selectors[11] = WalletWorkflowHandler.factoryOperatorChangesThenSyncs.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_walletFundsStayWithOwnersOrRegisteredProtocolTargets() public view {
        _assertAllSupplyIsAtOwnersCollectorsWalletsOrRegisteredTargets(IERC20(address(usdc)));
        _assertAllSupplyIsAtOwnersCollectorsWalletsOrRegisteredTargets(IERC20(address(rewardToken)));
        _assertAllSupplyIsAtOwnersCollectorsWalletsOrRegisteredTargets(IERC20(address(erc4626Vault)));
    }

    function invariant_attackerCannotPullOrReceiveWalletTokens() public view {
        assertFalse(handler.attackerPrivilegeSucceeded());
        assertFalse(handler.attackerReceivedWalletTokens());
        assertEq(usdc.balanceOf(attacker) + handler.attackerDonatedUsdc(), handler.attackerStartingUsdc());
        assertEq(rewardToken.balanceOf(attacker), 0);
        assertEq(weth.balanceOf(attacker), 0);
        assertEq(erc4626Vault.balanceOf(attacker), 0);
    }

    function invariant_operatorSetMatchesFactoryAfterSync() public view {
        _assertOperatorSetMatchesFactory(ownerAgent);
        _assertOperatorSetMatchesFactory(ownerSecondAgent);
        _assertOperatorSetMatchesFactory(otherOwnerAgent);
    }

    function afterInvariant() public view {
        console2.log("wallet invariant user deposits", handler.depositCalls());
        console2.log("wallet invariant vault workflows", handler.vaultCalls());
        console2.log("wallet invariant swap workflows", handler.swapCalls());
        console2.log("wallet invariant withdrawals", handler.ownerWithdrawalCalls() + handler.otherOwnerWithdrawalCalls());
        console2.log("wallet invariant owner blocklist changes", handler.blocklistCalls());
        console2.log("wallet invariant agent transfers", handler.transferCalls());
        console2.log("wallet invariant attacker attempts", handler.attackCalls());
        console2.log("wallet invariant donations", handler.donationCalls());
        console2.log("wallet invariant registry emergency calls", handler.emergencyCalls());
        console2.log("wallet invariant operator syncs", handler.operatorSyncCalls());
    }

    function _assertAllSupplyIsAtOwnersCollectorsWalletsOrRegisteredTargets(IERC20 token) private view {
        uint256 accounted = token.balanceOf(owner) + token.balanceOf(otherOwner) + token.balanceOf(address(handler.ownerAgent())) + token.balanceOf(address(handler.ownerSecondAgent())) + token.balanceOf(address(handler.otherOwnerAgent()))
            + token.balanceOf(feeCollector) + token.balanceOf(attacker);
        address[] memory vaultTargets = vaultRegistry.getAllTargets();
        address[] memory borrowTargets = borrowRegistry.getAllTargets();
        address[] memory seen = new address[](vaultTargets.length + borrowTargets.length);
        uint256 seenCount;
        for (uint256 i; i < vaultTargets.length; ++i) {
            accounted += token.balanceOf(vaultTargets[i]);
            seen[seenCount++] = vaultTargets[i];
        }
        for (uint256 i; i < borrowTargets.length; ++i) {
            bool duplicate;
            for (uint256 j; j < seenCount; ++j) {
                if (seen[j] == borrowTargets[i]) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) accounted += token.balanceOf(borrowTargets[i]);
        }
        assertEq(accounted, token.totalSupply());
    }

    function _assertOperatorSetMatchesFactory(AgentWallet wallet) private view {
        address[] memory actual = wallet.listAgentOperators();
        address[] memory expected = factory.listAgentOperators();
        assertEq(actual.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(wallet.isAgentOperator(expected[i]));
        }
        for (uint256 i; i < actual.length; ++i) {
            assertTrue(factory.hasRole(factory.AGENT_OPERATOR_ROLE(), actual[i]));
        }
    }
}
