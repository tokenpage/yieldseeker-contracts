// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "../src/AgentWalletFactory.sol";
import "../src/ActionRegistry.sol";
import "../src/adapters/ERC4626Adapter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

    interface IUsdc {
        function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
        function mint(address to, uint256 amount) external returns (bool);
    }

contract DemoFlow is Script, Test {
    // Base Mainnet Addresses
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant TARGET_VAULT = 0xE74c499fA461AF1844fCa84204490877787cED56; // Morpho Vault

    // Base USDC Master Minter
    address constant MASTER_MINTER = 0x2230393EDAD0299b7E7B59F20AA856cD1bEd52e1;

    function run() public {
        // Load addresses from recent deployment
        string memory json = vm.readFile("./deployments.json");
        address factoryAddress = vm.parseJsonAddress(json, ".AgentWalletFactory");
        address registryAddress = vm.parseJsonAddress(json, ".ActionRegistry");
        address erc4626AdapterAddress = 0xeB17210ea93f388D08246776F3Fa16C52CbBF17F;

        AgentWalletFactory factory = AgentWalletFactory(factoryAddress);
        ActionRegistry registry = ActionRegistry(registryAddress);
        ERC4626Adapter adapter = ERC4626Adapter(erc4626AdapterAddress);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); // Default Anvil Key
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Register the Target Vault
        console.log("Registering Target Vault:", TARGET_VAULT);
        try registry.registerTarget(TARGET_VAULT, erc4626AdapterAddress) {
            console.log("Target Registered.");
        } catch {
            console.log("Target might already be registered.");
        }

        // 2. Create Agent Wallet
        address user = address(0x123456); // Arbitrary user
        AgentWallet wallet = factory.createAccount(user, 999);
        console.log("AgentWallet Created at:", address(wallet));

        // 3. Fund Wallet via Master Minter Impersonation (God Mode)
        console.log("Funding Wallet via MasterMinter...");
        vm.stopBroadcast();

        vm.startBroadcast(MASTER_MINTER);
        IUsdc(USDC).configureMinter(deployer, type(uint256).max);
        vm.stopBroadcast();

        vm.startBroadcast(deployerPrivateKey);
        IUsdc(USDC).mint(address(wallet), 100 * 1e6);
        vm.stopBroadcast();

        uint256 bal = IERC20(USDC).balanceOf(address(wallet));
        console.log("Wallet Balance:", bal);
        require(bal >= 100 * 1e6, "Minting failed");

        // 4. Execute Deposit (Real Vault)
        vm.startBroadcast(user); // Impersonate the user
        bytes memory data = abi.encodeWithSelector(ERC4626Adapter.deposit.selector, TARGET_VAULT, 50 * 1e6);

        console.log("Executing Deposit (Real Target)...");
        wallet.executeViaAdapter(address(adapter), data);

        console.log("Deposit Complete.");

        // Check Shares
        uint256 shares = IERC4626(TARGET_VAULT).balanceOf(address(wallet));
        console.log("Agent Shares in Vault:", shares);

        require(shares > 0, "Deposit failed, no shares received");

        vm.stopBroadcast();
    }
}
