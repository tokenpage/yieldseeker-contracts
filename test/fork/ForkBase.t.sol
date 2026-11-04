// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {Test} from "forge-std/Test.sol";

abstract contract ForkBase is Test {
    bytes32 internal constant VAULT_AGENT_PROFILE = keccak256("vault");
    uint256 internal constant YIELD_FEE_BPS = 1000;

    address internal operator = makeAddr("operator");
    address internal owner = makeAddr("owner");
    address internal feeCollector = makeAddr("feeCollector");

    AgentWalletFactory internal factory;
    AdapterRegistry internal vaultRegistry;
    FeeTracker internal vaultFeeTracker;
    YieldSeekerYieldFeeModule internal vaultYieldFeeModule;

    function setUp() public virtual {
        if (block.chainid != 8453) vm.skip(true);
        vm.deal(operator, 1 ether);
        vm.deal(owner, 1 ether);

        vaultFeeTracker = new FeeTracker(address(this), feeCollector);
        vaultYieldFeeModule = new YieldSeekerYieldFeeModule(vaultFeeTracker, 5000);
        vaultFeeTracker.setFeeModule(YIELD_FEE, vaultYieldFeeModule);
        vaultFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_FEE_BPS})));

        vaultRegistry = new AdapterRegistry(address(this), address(this));
        factory = new AgentWalletFactory(address(this), address(this), operator);
        factory.setAgentWalletImplementation(new AgentWallet(address(factory)));
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, vaultRegistry);
        factory.setFeeTracker(VAULT_AGENT_PROFILE, vaultFeeTracker);
        vaultFeeTracker.setWalletFactory(address(factory));
    }

    function _registerAdapter(address adapter, address target) internal {
        if (!vaultRegistry.isRegisteredAdapter(adapter)) vaultRegistry.registerAdapter(adapter);
        vaultRegistry.setTargetAdapter(target, adapter);
    }

    function _createVaultWallet(address asset, uint256 index) internal returns (AgentWallet wallet) {
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.prank(operator);
        wallet = factory.createAgentWallet(owner, index, asset, VAULT_AGENT_PROFILE, noFeePlans);
    }

    function _execute(AgentWallet wallet, address adapter, address target, bytes memory data) internal returns (bytes memory result) {
        vm.prank(operator);
        result = wallet.executeViaAdapter(adapter, target, data);
    }
}
