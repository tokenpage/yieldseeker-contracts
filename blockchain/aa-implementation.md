# AA Implementation Guide

> **Note on Contract Names**: All contract classes use the `YieldSeeker` prefix for branding clarity (e.g., `YieldSeekerAgentWallet`, `YieldSeekerAgentWalletFactory`). File names remain unchanged (`AgentWallet.sol`, `AgentWalletFactory.sol`, etc.) to preserve git history. This document uses both names interchangeably - they refer to the same contracts.

This document describes the implemented Account Abstraction smart contracts and how to use them.

## What Was Built

Complete AA smart contract system implementing the architecture from `solution-aa.md`:

### Smart Contracts

**Core Infrastructure** (`blockchain/contracts/src/`)
- `YieldSeekerAgentWallet` (in `AgentWallet.sol`) - Implementation contract with wallet logic and security constraints
- `YieldSeekerAgentWalletFactory` (in `AgentWalletFactory.sol`) - Factory for deploying agent wallets (uses OpenZeppelin Clones)
- `YieldSeekerAccessController` (in `AccessController.sol`) - Central authorization gateway for backend operations

**Vaults** (`blockchain/contracts/src/vaults/`)
- `IVaultProvider.sol` - Interface for vault provider wrappers
- `YieldSeekerVaultRegistry` (in `VaultRegistry.sol`) - Whitelist of approved vault providers
- `ERC4626VaultProvider.sol` - Wrapper for ERC4626 vaults
- `AaveV3VaultProvider.sol` - Wrapper for Aave V3

**Swaps** (`blockchain/contracts/src/swaps/`)
- `ISwapProvider.sol` - Interface for swap provider wrappers
- `YieldSeekerSwapRegistry` (in `SwapRegistry.sol`) - Whitelist of approved swap providers
- `UniswapV3SwapProvider.sol` - Wrapper for Uniswap V3
- `AerodromeSwapProvider.sol` - Wrapper for Aerodrome DEX

**Testing & Deployment**
- `test/AgentWallet.t.sol` - Test suite
- `script/DeployDeterministic.s.sol` - CREATE2 deployment for deterministic addresses

## Directory Structure

```
blockchain/
├── current.md              # Current architecture (context for agents)
├── solution-aa.md          # AA architecture spec (context for agents)
├── solution-vault.md       # Alternative pooled vault approach
├── aa-implementation.md    # This file - implementation guide
└── contracts/
    ├── foundry.toml
    ├── Makefile
    ├── src/
    │   ├── AgentWallet.sol
    │   ├── AgentWalletFactory.sol      # Uses OpenZeppelin Clones (EIP-1167)
    │   ├── AccessController.sol
    │   ├── vaults/
    │   │   ├── IVaultProvider.sol
    │   │   ├── VaultRegistry.sol
    │   │   ├── ERC4626VaultProvider.sol
    │   │   └── AaveV3VaultProvider.sol
    │   └── swaps/
    │       ├── ISwapProvider.sol
    │       ├── SwapRegistry.sol
    │       ├── UniswapV3SwapProvider.sol
    │       └── AerodromeSwapProvider.sol
    ├── test/
    │   └── AgentWallet.t.sol
    └── script/
        └── DeployDeterministic.s.sol
```

## Security Model

```
Backend EOAs → YieldSeekerAccessController → Agent Wallets
               (authorization)        (funds)
                    ↓
         VaultRegistry + SwapRegistry
                    ↓
           Approved Providers
```

**Three-Layer Security:**

1. **YieldSeekerAccessController** - Manages backend EOA authorization, 1-tx key rotation, emergency pause
2. **VaultRegistry + SwapRegistry** - Whitelists approved protocols (CRITICAL: admin = god mode)
3. **AgentWallet** - Enforces constrained operations, user-only withdrawals

**Minimal Proxy Pattern:**
- Uses **OpenZeppelin Clones** (EIP-1167) for battle-tested, gas-efficient agent deployment
- ~200 byte proxies delegate to shared AgentWallet implementation
- OpenZeppelin library is audited and used by 300k+ projects
- Replaces custom proxy implementation with industry standard

**Security Guarantee:** Even with fully compromised backend, funds cannot be stolen (only suboptimal rebalancing possible).

## Key Features

### 🌍 Multi-Chain Agent Addresses (CREATE2)

Agents have the **same address on every chain** using CREATE2 deterministic deployment:

```solidity
// Deploy agent with deterministic address
factory.createAgentWallet(userAddress, agentIndex);

// Same agent address on Base, Optimism, Arbitrum, etc.
address predicted = factory.predictAgentWalletAddress(userAddress, agentIndex);
```

**How it works:**
- Salt = `keccak256(abi.encodePacked(userAddress, agentIndex))`
- Same factory address + same implementation address + same salt = same agent address
- User's first agent (index 0) will be at the same address across all chains
- User's second agent (index 1) will be at a different but also deterministic address

**Requirements for cross-chain consistency:**
1. Factory deployed at same address on all chains
2. AgentWallet implementation at same address on all chains
3. Same user address + agent index

**Benefits:**
- Simplified UX - one agent address across all chains
- Easy cross-chain position tracking
- Future cross-chain rebalancing support

### 👥 Multiple Agents Per User

Users can create unlimited agents, each with deterministic addresses:

```solidity
// User creates first agent (index 0)
address agent1 = factory.createAgentWallet(user, 0);

// User creates second agent (index 1)
address agent2 = factory.createAgentWallet(user, 1);

// Both agents on same address across all chains
```

## Quick Start

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Navigate to contracts
cd blockchain/contracts

# Build (auto-installs dependencies)
make build

# Run tests
make test

# Deploy to testnet
cp .env.example .env
# Edit .env with keys
make deploy-testnet
```

## Python Backend Integration

### 1. Agent Wallet Creation

**Before (EOA):**
```python
walletAddress = await self.coinbaseCdpClient.create_eoa()
```

**After (Smart Contract with CREATE2):**
```python
# Predict agent address before deployment (same on all chains!)
agentIndex = 0  # User's first agent
predictedAddress = factoryContract.functions.predictAgentWalletAddress(
    userAddress,
    agentIndex
).call()

# Deploy agent wallet
factoryContract = self.web3.eth.contract(
    address=AGENT_WALLET_FACTORY_ADDRESS,
    abi=AGENT_WALLET_FACTORY_ABI
)

tx = factoryContract.functions.createAgentWallet(
    userAddress,
    agentIndex  # 0 for first agent, 1 for second, etc.
).build_transaction({
    'from': BACKEND_OPERATOR_ADDRESS,
    'nonce': await self.web3.eth.get_transaction_count(BACKEND_OPERATOR_ADDRESS),
})

signedTx = self.web3.eth.account.sign_transaction(tx, BACKEND_OPERATOR_PRIVATE_KEY)
txHash = await self.web3.eth.send_raw_transaction(signedTx.rawTransaction)
receipt = await self.web3.eth.wait_for_transaction_receipt(txHash)

agentWalletAddress = factoryContract.events.AgentWalletCreated().process_receipt(receipt)[0]['args']['agentWallet']

# Verify deterministic address
assert agentWalletAddress == predictedAddress
```

**Multi-Agent Support:**
```python
# User creates multiple agents
agent1 = await create_agent_wallet(userAddress, agentIndex=0)  # Conservative strategy
agent2 = await create_agent_wallet(userAddress, agentIndex=1)  # Aggressive strategy
agent3 = await create_agent_wallet(userAddress, agentIndex=2)  # Stablecoin only

# Each agent has same address on Base, Optimism, Arbitrum, etc.
```

### 2. Vault Operations

**Before:**
```python
# Returns raw contract calls for agent EOA
async def get_deposit_calls(self, walletAddress, assetAddress, amount, ...):
    return [EncodedCall(to=vaultAddress, data=...)]
```

**After:**
```python
# Returns call to AgentWallet.depositToVault()
async def get_deposit_calls_aa(self, agentWalletAddress, assetAddress, amount, vaultProviderAddress):
    agentContract = self.web3.eth.contract(
        address=agentWalletAddress,
        abi=AGENT_CONTROLLER_ABI
    )

    return [EncodedCall(
        to=agentWalletAddress,
        data=agentContract.encodeABI(
            fn_name='depositToVault',
            args=[vaultProviderAddress, assetAddress, amount]
        )
    )]
```

### 3. Batch Rebalancing with Swaps

```python
async def execute_rebalance_aa(
    self,
    agentWallet: AgentWallet,
    targetAllocations: list[TargetAllocation],
    rewardSwaps: list[RewardSwap],
):
    actions = []

    # Swap rewards to USDC
    for rewardSwap in rewardSwaps:
        actions.append({
            'actionType': 2,  # SWAP
            'vault': ZERO_ADDRESS,
            'swapProvider': rewardSwap.swapProviderAddress,
            'tokenIn': rewardSwap.tokenIn,
            'tokenOut': rewardSwap.tokenOut,
            'amount': rewardSwap.amountIn,
            'minAmountOut': rewardSwap.minAmountOut,
        })

    # Withdraw from old vaults
    for allocation in targetAllocations:
        if allocation.delta < 0:
            actions.append({
                'actionType': 1,  # WITHDRAW
                'vault': allocation.vaultAddress,
                'amount': abs(allocation.delta),
            })

    # Deposit to new vaults
    for allocation in targetAllocations:
        if allocation.delta > 0:
            actions.append({
                'actionType': 0,  # DEPOSIT
                'vault': allocation.vaultAddress,
                'tokenIn': USDC_ADDRESS,
                'amount': allocation.delta,
            })

    # Execute atomically
    agentContract = self.web3.eth.contract(address=agentWallet.walletAddress, abi=AGENT_CONTROLLER_ABI)
    tx = agentContract.functions.rebalance(actions).build_transaction({
        'from': BACKEND_OPERATOR_ADDRESS,
    })

    signedTx = self.web3.eth.account.sign_transaction(tx, BACKEND_OPERATOR_PRIVATE_KEY)
    txHash = await self.web3.eth.send_raw_transaction(signedTx.rawTransaction)
```

## Deterministic Multi-Chain Deployment

**CRITICAL**: To enable cross-chain agent addresses, the `AgentWalletFactory` MUST be deployed at the same address on every chain.

### Solution: Safe Singleton Factory (CREATE2)

We use the [Safe Singleton Factory](https://github.com/safe-global/safe-singleton-factory) at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` (already deployed on 100+ chains).

**How it works**:
1. Same factory address (`0x914d7...`) on all chains
2. Same deterministic salt for each contract
3. Same bytecode on all chains
4. **Result**: Identical contract addresses everywhere

**Formula**:
```
address = keccak256(0xff, safe_factory, salt, keccak256(bytecode))
```

### Deployment Order (MUST be identical on all chains)

1. **VaultRegistry** - Vault provider whitelist
2. **SwapRegistry** - Swap provider whitelist
3. **YieldSeekerAccessController** - Backend authorization gateway
4. **AgentWallet** - Agent wallet implementation
5. **AgentWalletFactory** - Deploys agent wallets

### Deploy to All Chains

```bash
# Set environment variables
export DEPLOYER_ADDRESS=0x...
export PRIVATE_KEY=0x...

# Deploy to each chain (addresses will be IDENTICAL)
forge script script/DeployDeterministic.s.sol:DeployDeterministic \
  --rpc-url $BASE_RPC_URL --broadcast --verify

forge script script/DeployDeterministic.s.sol:DeployDeterministic \
  --rpc-url $OPTIMISM_RPC_URL --broadcast --verify

forge script script/DeployDeterministic.s.sol:DeployDeterministic \
  --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
```

**Verify Addresses Match**:
```bash
# All chains should show IDENTICAL addresses
forge script script/DeployDeterministic.s.sol:DeployDeterministic --rpc-url $BASE_RPC_URL
forge script script/DeployDeterministic.s.sol:DeployDeterministic --rpc-url $OPTIMISM_RPC_URL
```

### 2. Configure System

**Add Backend Operators:**
```solidity
operator.addOperator(0x...backend_eoa_1);
operator.addOperator(0x...backend_eoa_2);
```

**Approve Vault Providers:**
```solidity
vaultRegistry.approveProvider(aaveProviderAddress);
vaultRegistry.approveProvider(morphoProviderAddress);
```

**Approve Swap Providers:**
```solidity
swapRegistry.approveProvider(uniswapProviderAddress);
swapRegistry.approveProvider(aerodromeProviderAddress);
```

### 3. Database Schema

```sql
-- Track vault providers
CREATE TABLE tbl_vault_providers (
    vault_provider_id SERIAL PRIMARY KEY,
    chain_id INT NOT NULL,
    provider_address VARCHAR(42) NOT NULL,
    provider_type VARCHAR(50) NOT NULL,
    is_approved BOOLEAN DEFAULT false
);

-- Track swap providers
CREATE TABLE tbl_swap_providers (
    swap_provider_id SERIAL PRIMARY KEY,
    chain_id INT NOT NULL,
    provider_address VARCHAR(42) NOT NULL,
    provider_type VARCHAR(50) NOT NULL,
    is_approved BOOLEAN DEFAULT false
);

-- Track agent smart contract wallets
CREATE TABLE tbl_agent_wallet_contracts (
    agent_wallet_id UUID PRIMARY KEY,
    contract_address VARCHAR(42) NOT NULL,
    owner_address VARCHAR(42) NOT NULL
);
```

## Migration Strategy

**Phase 1: Deploy & Test** (Week 1)
- Deploy to Base Sepolia testnet
- Test all operations
- Security audit

**Phase 2: Parallel Operation** (Week 2-3)
- Deploy to Base mainnet
- New users get smart contract wallets
- Existing users keep EOA wallets

**Phase 3: Migration** (Week 4-6)
- Gradual migration of existing users
- Withdraw from EOA → transfer to smart contract
- Update database records

**Phase 4: Deprecation** (Week 7+)
- All operations use smart contracts
- Remove EOA code

## Critical Security Notes

⚠️ **Registry Admin Keys = God Mode**

The accounts controlling VaultRegistry and SwapRegistry can add malicious providers to steal all funds.

**Required Security:**
- Multi-sig wallet (3-of-5 Gnosis Safe minimum)
- 48-hour timelock on provider changes
- Public announcements for new providers
- Community review before approval

**Backend Operator Keys:**
- Separate keys for prod/dev/emergency
- Monitoring for unusual activity
- Can be rotated in 1 tx via YieldSeekerAccessController

## Testing

```bash
# Run all tests
make test

# Coverage report
make test-coverage

# Gas usage report
make test-gas

# Lint check
make lint-check

# Format code
make lint-fix
```

## Contract Addresses

**Base Sepolia (Testnet):**
```
VaultRegistry:       <address>
SwapRegistry:        <address>
YieldSeekerAccessController: <address>
AgentWallet:     <address>
AgentWalletFactory:  <address>
```

**Base (Mainnet):**
```
VaultRegistry:       <address>
SwapRegistry:        <address>
YieldSeekerAccessController: <address>
AgentWallet:     <address>
AgentWalletFactory:  <address>
```

## Support

- Architecture docs: `solution-aa.md`
- Current system: `current.md`
- Contract code: `blockchain/contracts/src/`
