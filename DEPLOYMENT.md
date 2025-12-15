# Deployment Guide for blockchain4

## Setup

This process requires these defined environment variables:
1. DEPLOYER_ADDRESS: the address of the contract deployers
1. DEPLOYER_PRIVATE_KEY: used to actually deploy all the contracts
1. SERVER_ADDRESS: the EOA the server is configured to use to make calls

## Contract Deployment

```bash
# Deploy all contracts
forge script script/Deploy.s.sol:DeployScript \
  --rpc-url $RPC_NODE_URL_8453 \
  --broadcast \
  --verify

# Deployment addresses will be saved to deployments.json
```

## Post-Deployment Configuration

After deployment, you need to configure the system:

#### 1. Set YieldSeeker Server Address

```bash
# Get the registry address from deployments.json
REGISTRY=$(jq -r '.ActionRegistry' deployments.json)

# Set your server address
cast send $REGISTRY \
  "setYieldSeekerServer(address)" $SERVER_ADDRESS \
  --rpc-url $RPC_NODE_URL_8453 \
  --private-key $DEPLOYER_PRIVATE_KEY
```

#### 2. Register Target Vaults/Pools

```bash
# Get adapter addresses from deployments.json
ERC4626_ADAPTER=$(jq -r '.ERC4626Adapter' deployments.json)
AAVE_ADAPTER=$(jq -r '.AaveV3Adapter' deployments.json)

VAULT_ADDRESS=<>
registerTarget=<>

# Register an ERC4626 vault (e.g., Morpho)
cast send $REGISTRY \
  "registerTarget(address,address)" \
  $VAULT_ADDRESS \
  $ERC4626_ADAPTER \
  --rpc-url $RPC_NODE_URL_8453 \
  --private-key $DEPLOYER_PRIVATE_KEY

# Register Aave V3 pool
cast send $REGISTRY \
  "registerTarget(address,address)" \
  $AAVE_POOL_ADDRESS \
  $AAVE_ADAPTER \
  --rpc-url $RPC_NODE_URL_8453 \
  --private-key $DEPLOYER_PRIVATE_KEY
```

---

## Selective Redeployment

If you need to redeploy only specific contracts (e.g., just the implementation), you can hardcode existing addresses in `Deploy.s.sol`:

### Example: Redeploy only Implementation

1. Open `script/Deploy.s.sol`
2. Find the hardcoded addresses section at the top
3. Uncomment and set the addresses you want to keep:

```solidity
// Uncomment to use existing contracts
address constant HARDCODED_REGISTRY = 0x05dDC2700Dd4d9b4DAC2C76C10d5df3666E590a7;
address constant HARDCODED_FACTORY = 0x770Ca6B6ed9222f7EAA919dAd0634888a89c87fB;
// address constant HARDCODED_IMPLEMENTATION = 0x...; // Leave commented to redeploy
address constant HARDCODED_ERC4626_ADAPTER = 0xeB17210ea93f388D08246776F3Fa16C52CbBF17F;
address constant HARDCODED_AAVE_ADAPTER = 0x...;
```

4. Update the if statements to use the hardcoded addresses:

```solidity
// Change from:
// if (false) { // Change to: if (true) to use hardcoded address

// To:
if (true) { // Using hardcoded address
    registry = ActionRegistry(HARDCODED_REGISTRY);
    console.log("Using existing ActionRegistry:", address(registry));
} else {
```

5. Run the deployment script again - it will only deploy the contracts you didn't hardcode

---

## Testing with Python Backend

After deployment, test the system with your Python backend:

### 1. Update Backend Configuration

Update your Python backend with the deployed addresses from `deployments.json`:

```python
FACTORY_ADDRESS = "0x..."  # From deployments.json
REGISTRY_ADDRESS = "0x..."
IMPLEMENTATION_ADDRESS = "0x..."
```

### 2. Create Test Wallet

```python
# Use your backend to create a wallet for a test user
wallet_address = create_agent_wallet(user_address, salt=0)
```

### 3. Fund Test Wallet

```python
# Send some USDC to the wallet
usdc.transfer(wallet_address, 1000 * 10**6)  # 1000 USDC
```

### 4. Execute Adapter Action

```python
# Sign a UserOperation to deposit to a vault
user_op = sign_user_operation(
    wallet=wallet_address,
    calldata=encode_execute_via_adapter(
        adapter=ERC4626_ADAPTER,
        data=encode_deposit(vault_address, amount)
    )
)

# Submit to bundler
bundler.submit_user_op(user_op)
```

### 5. Verify State

```python
# Check wallet now holds vault shares
shares = vault.balanceOf(wallet_address)
assert shares > 0, "Deposit failed"
```

---

## Deployment Checklist

- [ ] Deploy contracts to Base mainnet
- [ ] Verify contracts on Basescan
- [ ] Set YieldSeeker server address in registry
- [ ] Register target vaults/pools
- [ ] Create test wallet via factory
- [ ] Fund test wallet with USDC
- [ ] Test adapter execution via Python backend
- [ ] Verify vault shares received
- [ ] Test user withdrawal
- [ ] Update production backend configuration

---

## Troubleshooting

### Contract Verification Failed

If Etherscan verification fails during deployment, you can verify manually:

```bash
forge verify-contract \
  <CONTRACT_ADDRESS> \
  src/AgentWallet.sol:AgentWallet \
  --rpc-url $RPC_NODE_URL_8453 \
  --constructor-args $(cast abi-encode "constructor(address,address)" <ENTRYPOINT> <FACTORY>)
```

### Transaction Reverts

Common revert reasons:

- `AdapterNotRegistered`: Adapter not registered in registry
- `VaultNotRegistered`: Target vault not registered for that adapter
- `NotAllowed`: Trying to call `execute()` or `executeBatch()` (disabled)
- `SIG_VALIDATION_FAILED`: Invalid signature (not from owner or server)

### Gas Estimation Issues

If gas estimation fails, try increasing the gas limit manually:

```bash
cast send <CONTRACT> <FUNCTION> <ARGS> \
  --gas-limit 500000 \
  --rpc-url $RPC_NODE_URL_8453 \
  --private-key $DEPLOYER_PRIVATE_KEY
```
