// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test, console} from "forge-std/Test.sol";

// Mock USDC for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

// Mock Vault for testing interaction
contract MockVault {
    using SafeERC20 for IERC20;
    IERC20 public asset;
    mapping(address => uint256) public balances;

    constructor(address _asset) {
        asset = IERC20(_asset);
    }

    function deposit(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }
}

// Adapter to interact with the vault
contract VaultAdapter {
    function deposit(address vault, uint256 amount) external {
        MockVault(vault).deposit(amount);
    }
}

// Adapter to approve tokens
contract TokenApproveAdapter {
    function approve(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }
}

contract GasComparisonTest is Test {
    YieldSeekerAgentWalletFactory factory;
    YieldSeekerAdapterRegistry registry;
    AgentWallet wallet;
    MockUSDC usdc;
    MockVault vault;
    VaultAdapter vaultAdapter;
    TokenApproveAdapter approveAdapter;

    address admin = address(0xAD);
    address operator = address(0x01);
    address user = address(0x02);

    function setUp() public {
        // Setup Factory and Registry
        registry = new YieldSeekerAdapterRegistry(admin, admin);
        factory = new YieldSeekerAgentWalletFactory(admin, operator);
        AgentWallet impl = new AgentWallet(address(factory));

        vm.startPrank(admin);
        factory.setAgentWalletImplementation(impl);
        factory.setAdapterRegistry(registry);

        // Setup Mocks and Adapters
        usdc = new MockUSDC();
        vault = new MockVault(address(usdc));
        vaultAdapter = new VaultAdapter();
        approveAdapter = new TokenApproveAdapter();

        registry.registerAdapter(address(vaultAdapter));
        registry.registerAdapter(address(approveAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        registry.setTargetAdapter(address(usdc), address(approveAdapter));
        vm.stopPrank();

        // Create Agent Wallet
        vm.prank(operator);
        wallet = factory.createAccount(user, 0, address(usdc));

        // Fund both user and wallet
        usdc.mint(user, 1000 * 10 ** 18);
        usdc.mint(address(wallet), 1000 * 10 ** 18);

        // Pre-approve for direct deposit to avoid measuring approval gas
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);

        // Pre-approve for wallet deposit
        vm.prank(user);
        wallet.executeViaAdapter(address(approveAdapter), abi.encodeWithSelector(TokenApproveAdapter.approve.selector, address(usdc), address(vault), type(uint256).max));
    }

    function test_CompareDepositGas() public {
        uint256 amount = 100 * 10 ** 18;

        // 1. Direct Deposit
        vm.prank(user);
        uint256 startGasDirect = gasleft();
        vault.deposit(amount);
        uint256 gasUsedDirect = startGasDirect - gasleft();

        // 2. Wallet Deposit (via executeViaAdapter)
        vm.prank(user);
        uint256 startGasWallet = gasleft();
        wallet.executeViaAdapter(address(vaultAdapter), abi.encodeWithSelector(VaultAdapter.deposit.selector, address(vault), amount));
        uint256 gasUsedWallet = startGasWallet - gasleft();

        console.log("--------------------------------------------------");
        console.log("Gas Comparison: Vault Deposit");
        console.log("Direct Deposit: ", gasUsedDirect);
        console.log("Wallet Deposit: ", gasUsedWallet);
        console.log("Overhead:       ", gasUsedWallet - gasUsedDirect);
        console.log("--------------------------------------------------");
    }

    function test_CompareBatchDepositGas() public {
        uint256 amount = 100 * 10 ** 18;

        // 1. Two Direct Deposits (Simulating two separate transactions)
        // Note: In a real scenario, each would pay 21,000 base gas.
        // Here we just measure the execution gas.
        vm.prank(user);
        uint256 startGasDirect1 = gasleft();
        vault.deposit(amount);
        uint256 gasUsedDirect1 = startGasDirect1 - gasleft();

        vm.prank(user);
        uint256 startGasDirect2 = gasleft();
        vault.deposit(amount);
        uint256 gasUsedDirect2 = startGasDirect2 - gasleft();

        // 2. Batch Deposit (Two deposits in one transaction)
        address[] memory adapters = new address[](2);
        adapters[0] = address(vaultAdapter);
        adapters[1] = address(vaultAdapter);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(VaultAdapter.deposit.selector, address(vault), amount);
        datas[1] = abi.encodeWithSelector(VaultAdapter.deposit.selector, address(vault), amount);

        vm.prank(user);
        uint256 startGasBatch = gasleft();
        wallet.executeViaAdapterBatch(adapters, datas);
        uint256 gasUsedBatch = startGasBatch - gasleft();

        console.log("--------------------------------------------------");
        console.log("Gas Comparison: Batch Vault Deposit (2x)");
        console.log("2x Direct Deposits (Execution only): ", gasUsedDirect1 + gasUsedDirect2);
        console.log("1x Batch Wallet Deposit:             ", gasUsedBatch);
        console.log("Savings vs 2 separate TXs (est):     ", (21000 * 2 + gasUsedDirect1 + gasUsedDirect2) - (21000 + gasUsedBatch));
        console.log("--------------------------------------------------");
    }
}
