# ERC-4337 + ERC-7579 Smart Wallet for Yield Seeker

This directory contains an ERC-4337 (Account Abstraction) and ERC-7579 (Modular Smart Account) compliant wallet system for the Yield Seeker platform.

## Architecture

### Core Contracts

#### YieldSeekerAgentWallet (`src/AgentWallet.sol`)
The user's Smart Wallet.
- **Standards**: ERC-4337 + ERC-7579 + UUPS Upgradeable
- **Deployment**: Deployed as an **ERC1967Proxy** via the Factory
- **Role**: Secure shell that holds funds and executes instructions from authorized modules
- **Entry Points**:
  - Direct: Owner can call `execute()` directly
  - ERC-4337: EntryPoint calls `validateUserOp()` → `execute()`
  - Module: Installed executor modules call `executeFromExecutor()`
- **Upgrades**: Only the **User (Owner)** can upgrade their wallet

#### AgentWalletFactory (`src/AgentWalletFactory.sol`)
Factory for deploying wallets.
- **Mechanism**: Deploys ERC1967 Proxies with auto-installed Router module
- **Benefit**: Ensures user sovereignty (no forced upgrades)

### Modules (`src/modules/`)

#### AgentActionRouter
The "Executor Module" auto-installed on every wallet.
- **Role**: Entry point for the Backend Operator
- **Function**: `executeAction(wallet, target, value, data)`
- **Logic**: Delegates validation to `AgentActionPolicy`
- **Dual Access**: Supports both direct operator calls and wallet-mediated ERC-4337 calls
- **Benefit**: Allows global policy updates without touching user wallets

#### AgentActionPolicy
The "Brain" logic contract.
- **Role**: Defines the Allowlist mapping (Target + Selector → Validator)
- **Updates**: Can be swapped globally by updating the Router

### Validators (`src/validators/`)

#### MerklValidator
Validates Merkl Distributor reward claims.
- Ensures agents can only claim rewards for themselves

#### ZeroExValidator
Validates 0x Protocol swaps.
- Ensures swap output token matches wallet's base asset (e.g., USDC)

### Vault Wrappers (`src/vaults/`)

#### ERC4626VaultWrapper
Combined wrapper + validator for ERC4626 vaults (Yearn V3, MetaMorpho, etc.)
- Acts as both `IPolicyValidator` and execution wrapper
- Handles deposit/withdraw with proper token approvals

#### AaveV3VaultWrapper
Combined wrapper + validator for Aave V3.
- Manages supply/withdraw operations
- Handles aToken minting/burning

## ERC-4337 Integration

Uses the canonical EntryPoint V0.8:
- **Address**: `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`
- **Gas Sponsorship**: Use Coinbase Paymaster (or any compatible paymaster)

## Usage Flow

1. **Deploy Infrastructure**:
   - Deploy `YieldSeekerAgentWallet` (Implementation)
   - Deploy `AgentWalletFactory` (with implementation + router)
   - Deploy `AgentActionPolicy`
   - Deploy `AgentActionRouter` (pointing to Policy)
   - Deploy Vault Wrappers and Validators

2. **Configure Policy**:
   - `policy.setPolicy(wrapperAddress, depositSelector, wrapperAddress)`
   - `router.setOperator(backendServerAddress, true)`

3. **Create User Wallet**:
   - `factory.createAgentWallet(owner, salt)` → Router auto-installed

4. **Daily Operation** (Two modes):
   - **Direct**: Operator calls `router.executeAction(wallet, target, value, data)`
   - **ERC-4337**: Submit UserOperation → EntryPoint → Wallet → Router

5. **Global Policy Upgrade**:
   - Deploy `AgentActionPolicyV2`, call `router.setPolicy(V2)`

6. **Wallet Implementation Upgrade**:
   - Deploy new implementation, user calls `wallet.upgradeToAndCall()`

## Benefits
- **ERC-4337 Compliant**: Gas sponsorship, batched operations, social recovery ready
- **ERC-7579 Modular**: Swap modules without wallet upgrades
- **Security**: Granular parameter validation per action type
- **Flexibility**: Add new validators without upgrading accounts
