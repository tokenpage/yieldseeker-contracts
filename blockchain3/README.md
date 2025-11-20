# Minimal ERC-7579 Implementation for Yield Seeker

This directory contains a minimal implementation of the ERC-7579 Modular Smart Account standard, tailored for the "Restricted Operator" use case.

## Architecture

### 1. YieldSeekerAgentWallet (`src/AgentWallet.sol`)
The user's Smart Wallet.
- **Type**: ERC-7579 + UUPS Upgradeable.
- **Deployment**: Deployed as an **ERC1967Proxy** via the Factory.
- **Role**: A secure shell that holds funds and executes instructions from authorized modules.
- **Upgrades**: Only the **User (Owner)** can upgrade their wallet implementation.

### 2. AgentWalletFactory (`src/AgentWalletFactory.sol`)
Factory for deploying wallets.
- **Mechanism**: Deploys standard ERC1967 Proxies.
- **Benefit**: Ensures user sovereignty (no forced upgrades).

### 3. AgentActionRouter (`src/modules/AgentActionRouter.sol`)
The "Executor Module" installed on every wallet.
- **Role**: The entry point for the Backend Server.
- **Function**: `executeAction(wallet, target, data)`.
- **Logic**: It delegates validation to the `AgentActionPolicy`.
- **Benefit**: Allows global policy updates without touching user wallets.

### 4. AgentActionPolicy (`src/modules/AgentActionPolicy.sol`)
The "Brain" logic contract.
- **Role**: Defines the Allowlist (Target + Selector -> Validator).
- **Updates**: Can be swapped out globally by updating the Router.

### 5. VaultValidator (`src/modules/VaultValidator.sol`)
Specific parameter validation logic.
- Example: Checks that `deposit(asset, amount)` uses the correct asset.

## Usage Flow

1.  **Deploy Infrastructure**:
    - Deploy `YieldSeekerAgentWallet` (Implementation).
    - Deploy `AgentWalletFactory` (with implementation).
    - Deploy `AgentActionPolicy` (V1).
    - Deploy `AgentActionRouter` (pointing to Policy V1).
    - Deploy `VaultValidator`.

2.  **Configure Policy**:
    - `policy.setPolicy(vaultAddress, depositSelector, vaultValidatorAddress)`.
    - `router.setOperator(backendServerAddress, true)`.

3.  **Create User Wallet**:
    - `factory.createAgentWallet(owner, salt)`.
    - *Note: In production, the factory should auto-install the Router module.*

4.  **Daily Operation**:
    - Server calls `router.executeAction(walletAddress, vaultAddress, 0, data)`.
    - Router checks Policy -> Policy checks Validator -> Wallet executes.

5.  **Global Policy Upgrade**:
    - Deploy `AgentActionPolicyV2`, call `router.setPolicy(V2)`. All wallets updated instantly.

6.  **Wallet Implementation Upgrade**:
    - Deploy `YieldSeekerAgentWalletV2`.
    - Factory admin calls `factory.setImplementation(V2)`.
    - **User Action Required**: User calls `wallet.upgradeTo(V2)` to get the new features.

## Benefits
- **Compliance**: Follows ERC-7579 standard.
- **Security**: Granular control over every parameter.
- **Flexibility**: Can add new Validators (e.g., for Swaps) without upgrading the Account or the Executor.
