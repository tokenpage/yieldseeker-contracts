// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerVaultAdapter as VaultAdapter} from "../src/adapters/VaultAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MockERC4626Vault is ERC20 {
    IERC20 public immutable ASSET;

    constructor(address _asset, string memory name, string memory symbol) ERC20(name, symbol) {
        ASSET = IERC20(_asset);
    }

    function asset() external view returns (address) {
        return address(ASSET);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        require(ASSET.transferFrom(msg.sender, address(this), assets), "Transfer failed");
        _mint(receiver, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(msg.sender == owner, "not owner");
        assets = shares;
        _burn(owner, shares);
        require(ASSET.transfer(receiver, assets), "Transfer failed");
        return assets;
    }
}

contract RebalanceTest is Test {
    AgentWallet public wallet;
    YieldSeekerAgentWalletFactory public factory;
    AdapterRegistry public registry;
    FeeTracker public tracker;
    ERC4626Adapter public adapter;

    MockUSDC public usdc;
    MockERC4626Vault public vaultA;
    MockERC4626Vault public vaultB;
    MockERC4626Vault public vaultC;

    address public owner = address(1);
    address public admin = address(2);
    address public feeCollector = address(3);

    function setUp() public {
        // Deploy USDC
        usdc = new MockUSDC();

        // Deploy AdminTimelock
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        YieldSeekerAdminTimelock timelock = new YieldSeekerAdminTimelock(0, proposers, executors, address(0));

        // Deploy core contracts
        tracker = new FeeTracker(address(timelock));
        registry = new AdapterRegistry(address(timelock), admin);
        factory = new YieldSeekerAgentWalletFactory(address(timelock), admin);

        // Deploy wallet implementation with factory address
        AgentWallet implementation = new AgentWallet(address(factory));

        // Deploy adapter
        adapter = new ERC4626Adapter();

        // Deploy vaults
        vaultA = new MockERC4626Vault(address(usdc), "Vault A", "vA");
        vaultB = new MockERC4626Vault(address(usdc), "Vault B", "vB");
        vaultC = new MockERC4626Vault(address(usdc), "Vault C", "vC");

        // Configure via timelock - each operation needs unique salt and time advancement
        uint256 salt = 1;

        bytes memory setFeeData = abi.encodeWithSelector(tracker.setFeeConfig.selector, 1000, feeCollector);
        vm.prank(admin);
        timelock.schedule(address(tracker), 0, setFeeData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(tracker), 0, setFeeData, bytes32(0), bytes32(salt - 1));

        bytes memory setImplData = abi.encodeWithSelector(factory.setAgentWalletImplementation.selector, implementation);
        vm.prank(admin);
        timelock.schedule(address(factory), 0, setImplData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(factory), 0, setImplData, bytes32(0), bytes32(salt - 1));

        bytes memory setRegistryData = abi.encodeWithSelector(factory.setAdapterRegistry.selector, registry);
        vm.prank(admin);
        timelock.schedule(address(factory), 0, setRegistryData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(factory), 0, setRegistryData, bytes32(0), bytes32(salt - 1));

        bytes memory setTrackerData = abi.encodeWithSelector(factory.setFeeTracker.selector, tracker);
        vm.prank(admin);
        timelock.schedule(address(factory), 0, setTrackerData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(factory), 0, setTrackerData, bytes32(0), bytes32(salt - 1));

        bytes memory regAdapterData = abi.encodeWithSelector(registry.registerAdapter.selector, address(adapter));
        vm.prank(admin);
        timelock.schedule(address(registry), 0, regAdapterData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(registry), 0, regAdapterData, bytes32(0), bytes32(salt - 1));

        bytes memory regVaultAData = abi.encodeWithSelector(registry.setTargetAdapter.selector, address(vaultA), address(adapter));
        vm.prank(admin);
        timelock.schedule(address(registry), 0, regVaultAData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(registry), 0, regVaultAData, bytes32(0), bytes32(salt - 1));

        bytes memory regVaultBData = abi.encodeWithSelector(registry.setTargetAdapter.selector, address(vaultB), address(adapter));
        vm.prank(admin);
        timelock.schedule(address(registry), 0, regVaultBData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(registry), 0, regVaultBData, bytes32(0), bytes32(salt - 1));

        bytes memory regVaultCData = abi.encodeWithSelector(registry.setTargetAdapter.selector, address(vaultC), address(adapter));
        vm.prank(admin);
        timelock.schedule(address(registry), 0, regVaultCData, bytes32(0), bytes32(salt++), 24 hours);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.prank(admin);
        timelock.execute(address(registry), 0, regVaultCData, bytes32(0), bytes32(salt - 1));

        // Create wallet as owner (admin has AGENT_OPERATOR_ROLE from factory constructor)
        vm.prank(admin);
        wallet = factory.createAgentWallet(owner, 0, address(usdc));

        // Fund wallet with USDC
        usdc.mint(address(wallet), 1000e6);
    }

    function test_RebalanceSimple() public {
        // Deposit 400 USDC into vaultA
        bytes memory depositData = abi.encodeWithSelector(adapter.deposit.selector, 400e6);
        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(vaultA), depositData);

        assertEq(vaultA.balanceOf(address(wallet)), 400e6);
        assertEq(usdc.balanceOf(address(wallet)), 600e6);

        // Rebalance: withdraw 200 from vaultA, deposit 100% into vaultB using executeViaAdapterBatch
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);

        address[] memory targets = new address[](2);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 200e6);
        datas[1] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 10000); // 100%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        // Check final state
        assertEq(vaultA.balanceOf(address(wallet)), 200e6); // 400 - 200
        assertEq(vaultB.balanceOf(address(wallet)), 800e6); // 600 + 200 (100% of available)
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_RebalanceMultipleDeposits() public {
        // Deposit 500 USDC into vaultA
        bytes memory depositData = abi.encodeWithSelector(adapter.deposit.selector, 500e6);
        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(vaultA), depositData);

        // Rebalance: withdraw all from vaultA, split 60/40 between vaultB and vaultC
        // depositPercentage applies sequentially: 60% of 1000 = 600, then 40% of 400 = 160
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);
        adapters[2] = address(adapter);

        address[] memory targets = new address[](3);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);
        targets[2] = address(vaultC);

        bytes[] memory datas = new bytes[](3);
        datas[0] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 500e6);
        datas[1] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 6000); // 60%
        datas[2] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 4000); // 40%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vaultA.balanceOf(address(wallet)), 0);
        assertEq(vaultB.balanceOf(address(wallet)), 600e6);
        assertEq(vaultC.balanceOf(address(wallet)), 160e6);
        assertEq(usdc.balanceOf(address(wallet)), 240e6); // remaining
    }

    function test_RebalanceMultipleWithdrawals() public {
        // Deposit into vaultA and vaultB
        bytes memory depositDataA = abi.encodeWithSelector(adapter.deposit.selector, 300e6);
        bytes memory depositDataB = abi.encodeWithSelector(adapter.deposit.selector, 400e6);

        vm.startPrank(owner);
        wallet.executeViaAdapter(address(adapter), address(vaultA), depositDataA);
        wallet.executeViaAdapter(address(adapter), address(vaultB), depositDataB);
        vm.stopPrank();

        // Rebalance: withdraw from both, deposit into vaultC
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);
        adapters[2] = address(adapter);

        address[] memory targets = new address[](3);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);
        targets[2] = address(vaultC);

        bytes[] memory datas = new bytes[](3);
        datas[0] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 150e6);
        datas[1] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 250e6);
        datas[2] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 10000); // 100%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        // Available balance after withdrawals: 300 + 150 + 250 = 700
        assertEq(vaultA.balanceOf(address(wallet)), 150e6);
        assertEq(vaultB.balanceOf(address(wallet)), 150e6);
        assertEq(vaultC.balanceOf(address(wallet)), 700e6); // 300 existing + 400 deposited
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_RebalancePartialDeposit() public {
        // Start with 1000 USDC
        // Rebalance: deposit only 50% into vaultA
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);

        address[] memory targets = new address[](1);
        targets[0] = address(vaultA);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 5000); // 50%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vaultA.balanceOf(address(wallet)), 500e6);
        assertEq(usdc.balanceOf(address(wallet)), 500e6);
    }

    function test_RebalanceEmptyWithdrawals() public {
        // No withdrawals, just deposits
        // Note: depositPercentage uses current balance, so percentages apply sequentially
        // 30% of 1000 = 300, then 30% of 700 = 210, then 40% of 490 = 196
        address[] memory adapters = new address[](3);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);
        adapters[2] = address(adapter);

        address[] memory targets = new address[](3);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);
        targets[2] = address(vaultC);

        bytes[] memory datas = new bytes[](3);
        datas[0] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 3000); // 30%
        datas[1] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 3000); // 30%
        datas[2] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 4000); // 40%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vaultA.balanceOf(address(wallet)), 300e6);
        assertEq(vaultB.balanceOf(address(wallet)), 210e6);
        assertEq(vaultC.balanceOf(address(wallet)), 196e6);
        assertEq(usdc.balanceOf(address(wallet)), 294e6); // remaining
    }

    function test_RebalanceEmptyDeposits() public {
        // Deposit first
        bytes memory depositData = abi.encodeWithSelector(adapter.deposit.selector, 500e6);
        vm.prank(owner);
        wallet.executeViaAdapter(address(adapter), address(vaultA), depositData);

        // Only withdrawals, no deposits (leaves USDC in wallet)
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);

        address[] memory targets = new address[](1);
        targets[0] = address(vaultA);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 500e6);

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vaultA.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1000e6);
    }

    function test_RebalanceRevertOnExceedingPercentage() public {
        // depositPercentage validates percentage <= 10000 internally
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);

        address[] memory targets = new address[](1);
        targets[0] = address(vaultA);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 11000); // 110%

        vm.expectRevert();
        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_RebalanceExactly100Percent() public {
        // depositPercentage applies sequentially: 75% of 1000 = 750, then 25% of 250 = 62.5
        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);

        address[] memory targets = new address[](2);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 7500); // 75%
        datas[1] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 2500); // 25%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertEq(vaultA.balanceOf(address(wallet)), 750e6);
        assertEq(vaultB.balanceOf(address(wallet)), 62.5e6);
        assertEq(usdc.balanceOf(address(wallet)), 187.5e6); // remaining
    }

    function test_RebalanceOnlyExecutorsCanCall() public {
        address[] memory adapters = new address[](0);
        address[] memory targets = new address[](0);
        bytes[] memory datas = new bytes[](0);

        vm.expectRevert();
        vm.prank(address(999)); // Random address
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_RebalanceComplexScenario() public {
        // Setup: deposit into all three vaults
        vm.startPrank(owner);
        wallet.executeViaAdapter(address(adapter), address(vaultA), abi.encodeWithSelector(adapter.deposit.selector, 200e6));
        wallet.executeViaAdapter(address(adapter), address(vaultB), abi.encodeWithSelector(adapter.deposit.selector, 300e6));
        wallet.executeViaAdapter(address(adapter), address(vaultC), abi.encodeWithSelector(adapter.deposit.selector, 400e6));
        vm.stopPrank();

        // Current state: vaultA=200, vaultB=300, vaultC=400, wallet=100

        // Rebalance: withdraw from A and B, deposit into B and C with 70/30 split
        // depositPercentage applies sequentially: 70% of 400 = 280, then 30% of 120 = 36
        address[] memory adapters = new address[](4);
        adapters[0] = address(adapter);
        adapters[1] = address(adapter);
        adapters[2] = address(adapter);
        adapters[3] = address(adapter);

        address[] memory targets = new address[](4);
        targets[0] = address(vaultA);
        targets[1] = address(vaultB);
        targets[2] = address(vaultB);
        targets[3] = address(vaultC);

        bytes[] memory datas = new bytes[](4);
        datas[0] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 200e6); // Withdraw all from A
        datas[1] = abi.encodeWithSelector(VaultAdapter.withdraw.selector, 100e6); // Withdraw partial from B
        datas[2] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 7000); // 70%
        datas[3] = abi.encodeWithSelector(VaultAdapter.depositPercentage.selector, 3000); // 30%

        vm.prank(owner);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        // Available after withdrawals: 100 + 200 + 100 = 400
        // 70% to B = 280, then 30% of 120 = 36 to C
        assertEq(vaultA.balanceOf(address(wallet)), 0);
        assertEq(vaultB.balanceOf(address(wallet)), 200e6 + 280e6); // Remaining 200 + new 280
        assertEq(vaultC.balanceOf(address(wallet)), 400e6 + 36e6); // Existing 400 + new 36
        assertEq(usdc.balanceOf(address(wallet)), 84e6); // remaining
    }
}
