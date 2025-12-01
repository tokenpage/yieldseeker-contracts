# Yield Seeker Smart Wallet System

## Overview

This is a **parameter-level validated smart wallet system** for autonomous agents. Unlike traditional smart wallets that only restrict which _functions_ can be called, this system validates the _parameters_ of each call to ensure security even when operators are compromised.

### The Problem with Traditional Smart Wallets

Consider an AI agent that autonomously moves USDC between yield vaults to maximize returns. To deposit into a vault, the agent needs to:

1. Call `USDC.approve(vault, amount)` - allow the vault to pull USDC
2. Call `vault.deposit(amount)` - trigger the deposit

Traditional smart wallets with operator permissions handle this by whitelisting functions:

```
Admin configures:
  ✓ Allow operator to call USDC.approve(spender, amount)
  ✓ Allow operator to call YearnVault.deposit(amount)
  ✓ Allow operator to call AavePool.supply(asset, amount, ...)
```

**The Problem**: The wallet allows `USDC.approve()` but cannot restrict the `spender` parameter. A malicious or compromised operator can:

```solidity
// Operator calls (perfectly "allowed" by traditional wallet):
USDC.approve(ATTACKER_CONTRACT, type(uint256).max);

// Attacker contract then drains all USDC:
USDC.transferFrom(wallet, attacker, USDC.balanceOf(wallet));
```

The wallet approved the call because `approve` was on the allowlist. It had no way to validate that the spender should only be a trusted vault.

### Our Solution: Parameter-Level Validation

Our system validates every parameter of every call:
- Admin configures: "For `USDC.approve()`, the spender must be in our vault allowlist"
- Operator tries: `USDC.approve(MALICIOUS_CONTRACT, MAX_UINT)`
- **Validator rejects**: Spender not in allowlist
- Operator tries: `USDC.approve(YEARN_VAULT, 1000e6)`
- **Validator approves**: Spender is whitelisted vault

This means even a fully compromised operator key cannot steal funds - they can only execute pre-approved actions with pre-approved parameters.

### Standards Compliance

| Standard | Purpose |
|----------|---------|
| **ERC-4337** | Account Abstraction - gas sponsorship, UserOperations |
| **ERC-7579** | Modular Smart Accounts - pluggable executor/validator modules |
| **ERC-7201** | Namespaced Storage - safe upgrades without storage collisions |
| **UUPS** | Upgradeable Proxies - user-controlled wallet upgrades |

---

## Timelock Architecture

All administrative actions that could compromise user funds are protected by a **24-48 hour timelock**. This ensures that even if admin keys are compromised, there's time to detect and respond before damage occurs.

### TimelockController Setup

We use OpenZeppelin's `TimelockController` as the admin for all critical contracts:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TimelockController                                  │
│  • minDelay: 24-48 hours                                                    │
│  • PROPOSER_ROLE: Admin Multisig                                            │
│  • EXECUTOR_ROLE: Admin Multisig (or open)                                  │
│  • CANCELLER_ROLE: Admin Multisig + Emergency EOA                           │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
          Holds DEFAULT_ADMIN_ROLE on all admin contracts
                              │
     ┌────────────────────────┼────────────────────────┐
     ▼                        ▼                        ▼
AgentActionRouter     AgentActionPolicy        VaultWrappers
AgentWalletFactory
```

### Timelocked vs Emergency Actions

| Contract | Timelocked (24h+) | Emergency (Instant) |
|----------|-------------------|---------------------|
| **AgentActionRouter** | `setPolicy()`, `addOperator()` | `removeOperator()` |
| **AgentActionPolicy** | `addPolicy()` | `removePolicy()` |
| **ERC4626VaultWrapper** | `addVault()` | `removeVault()` |
| **AaveV3VaultWrapper** | `addAsset()` | `removeAsset()` |
| **AgentWalletFactory** | `setImplementation()`, `setDefaultExecutor()` | — |

**Why this split?**
- **Adding** capabilities (operators, vaults, policies) → Must go through timelock
- **Removing** capabilities (for emergencies) → Instant response to threats

### Emergency Response Flow

If an operator key is compromised:
1. Emergency multisig calls `router.removeOperator(compromisedAddress)` immediately
2. Compromised operator can no longer execute any actions
3. Time to investigate and rotate keys without fund loss

---

## Architecture Overview

There are two entry paths into the system:

### Path 1: Direct Operator Call

The Router is a **shared singleton** - one Router serves all wallets. Operators call the Router directly, passing the target wallet address as a parameter.

**Why this pattern?** This is not a standard ERC-7579 pattern - it's our design choice for global updatability:
- Operators are registered once on the Router, not per-wallet
- Policy can be swapped globally via `router.setPolicy()` without touching wallets
- New validators can be added without any wallet upgrades

The tradeoff is that operators call the Router directly rather than the wallet. The wallet still enforces that only installed executor modules can trigger `executeFromExecutor()`.

```
Operator EOA
     │
     │ router.executeAction(wallet, target, value, data)
     │
     │ Note: Operator calls Router directly (not the wallet)
     │       Router is a shared contract that serves ALL wallets
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    AgentActionRouter (shared singleton)                     │
│  • Checks caller is authorized operator                                     │
│  • Calls Policy to validate parameters                                      │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ policy.validateAction(wallet, target, value, data)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AgentActionPolicy                                   │
│  • Looks up validator for (target, selector)                                │
│  • Calls validator to check parameters                                      │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ validator.validateAction(wallet, target, selector, data)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│              Validators (VaultWrappers, MerklValidator, etc.)               │
│  • Decode and validate specific parameters                                  │
│  • Return true/false                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ (if valid) wallet.executeFromExecutor(mode, calldata)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      YieldSeekerAgentWallet                                 │
│  • Checks Router is installed as executor module                            │
│  • Executes the validated call to target                                    │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     ▼
  Target Contract (Vault, DEX, etc.)
```

### Path 2: ERC-4337 UserOperation (Gas Sponsored)
```
Bundler submits UserOperation
     │
     │ entryPoint.handleOps([userOp], beneficiary)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     EntryPoint (v0.6 / v0.7 / v0.8)                         │
│  • Canonical ERC-4337 contract                                              │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ wallet.validateUserOp(userOp, hash, missingFunds)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      YieldSeekerAgentWallet                                 │
│  • Validates signature is from authorized operator                          │
│  • Pays prefund to EntryPoint if needed                                     │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ (if valid) entryPoint calls wallet.execute(mode, calldata)
     │ calldata = abi.encodeCall(router.executeAction, (...))
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      YieldSeekerAgentWallet.execute()                       │
│  • Decodes and executes the call                                            │
│  • Calls router.executeAction(...)                                          │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     │ router.executeAction(wallet, target, value, data)
     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AgentActionRouter                                   │
│  • Checks caller is wallet (allowed via onlyOperatorOrWallet)               │
│  • Validates via Policy → Validators (same as Path 1)                       │
│  • Calls wallet.executeFromExecutor()                                       │
└─────────────────────────────────────────────────────────────────────────────┘
     │
     ▼
  ... continues same as Path 1 ...
```

---

## Contract Reference

### Core Contracts

#### YieldSeekerAgentWallet (`src/AgentWallet.sol`)

The user's smart wallet that holds funds and executes validated operations.

**Inheritance Chain:**
```
ERC7579Account → Initializable → UUPSUpgradeable → OwnableUpgradeable
```

**Storage (ERC-7201 Namespaced):**
| Field | Type | Description |
|-------|------|-------------|
| `userAgentIndex` | `uint256` | Index for users with multiple agents |
| `baseAsset` | `address` | Primary asset (e.g., USDC) |
| `executorModule` | `address` | Reference to installed Router |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `initialize(user, index, baseAsset, executor)` | Factory only | Sets up wallet with owner and auto-installs Router |
| `execute(mode, calldata)` | EntryPoint/Self | ERC-7579 execution (called after validation) |
| `executeFromExecutor(mode, calldata)` | Installed Executors | Module-triggered execution |
| `validateUserOp(userOp, hash, funds)` | EntryPoint | ERC-4337 signature validation (v0.6, v0.7, v0.8) |
| `installModule(type, module, data)` | Owner only | Add new ERC-7579 module |
| `uninstallModule(type, module, data)` | Owner only | Remove ERC-7579 module |
| `withdrawTokenToUser(token, recipient, amount)` | Owner only | User withdraws ERC20 |
| `withdrawEthToUser(recipient, amount)` | Owner only | User withdraws ETH |
| `upgradeToAndCall(newImpl, data)` | Owner only | Upgrade to new implementation |

**EntryPoint Compatibility:**
| Version | Address | UserOp Format |
|---------|---------|---------------|
| v0.6 | `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789` | Unpacked `UserOperation` |
| v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Packed `PackedUserOperation` |
| v0.8 | `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108` | Packed `PackedUserOperation` |

---

#### AgentWalletFactory (`src/AgentWalletFactory.sol`)

Deploys new agent wallets as ERC1967 proxies with deterministic addresses.

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `createAgentWallet(user, index, baseAsset)` | AGENT_CREATOR_ROLE | Deploys new wallet via CREATE2 |
| `predictAgentWalletAddress(user, index, baseAsset)` | View | Predicts address before deployment |
| `setImplementation(newImpl)` | DEFAULT_ADMIN_ROLE | Updates implementation for new wallets |
| `setDefaultExecutor(executor)` | DEFAULT_ADMIN_ROLE | Sets Router to auto-install |

**Features:**
- **Deterministic Addresses**: Same user + index = same address across chains
- **Auto-Install Router**: New wallets have Router pre-installed
- **User Sovereignty**: Factory cannot force-upgrade existing wallets

---

### Modules (`src/modules/`)

#### AgentActionRouter (`src/modules/AgentActionRouter.sol`)

The ERC-7579 Executor Module that bridges operators to wallets.

**Roles (AccessControl):**
| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Can grant/revoke other roles (held by TimelockController) |
| `POLICY_ADMIN_ROLE` | Can update the Policy contract (timelocked) |
| `OPERATOR_ADMIN_ROLE` | Can add operators (timelocked) |
| `EMERGENCY_ROLE` | Can remove operators instantly |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `executeAction(wallet, target, value, data)` | Operators or Wallet | Validates via Policy, then executes |
| `addOperator(addr)` | OPERATOR_ADMIN_ROLE | Add authorized operator (timelocked) |
| `removeOperator(addr)` | EMERGENCY_ROLE | Remove operator instantly |
| `setPolicy(newPolicy)` | POLICY_ADMIN_ROLE | Update validation logic globally (timelocked) |

**Access Control:**
- `onlyOperatorOrWallet(wallet)`: Accepts calls from registered operators OR from the wallet itself (for ERC-4337 flow)

---

#### AgentActionPolicy (`src/modules/AgentActionPolicy.sol`)

The validation brain that maps actions to validators.

**Roles (AccessControl):**
| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Can grant/revoke other roles (held by TimelockController) |
| `POLICY_SETTER_ROLE` | Can add policy rules (timelocked) |
| `EMERGENCY_ROLE` | Can remove policy rules instantly |

**Storage:**
```solidity
mapping(address target => mapping(bytes4 selector => address validator)) public functionValidators;
```

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `addPolicy(target, selector, validator)` | POLICY_SETTER_ROLE | Add/update policy rule (timelocked) |
| `removePolicy(target, selector)` | EMERGENCY_ROLE | Remove policy rule instantly |
| `validateAction(wallet, target, value, data)` | View | Check if action is permitted |

**Validator Resolution:**
1. If `functionValidators[target][selector] == address(1)` → Allow without parameter check
2. If `functionValidators[target][selector] == validatorContract` → Call validator
3. Otherwise → Reject

---

### Validators (`src/validators/`)

#### MerklValidator (`src/validators/MerklValidator.sol`)

Validates Merkl Distributor reward claims.

**Validation Logic:**
- Decodes `claim(address[] users, ...)` parameters
- Ensures every `users[i] == wallet` (can only claim for self)

---

#### ZeroExValidator (`src/validators/ZeroExValidator.sol`)

Validates 0x Protocol swaps.

**Validation Logic:**
- Decodes `transformERC20(inputToken, outputToken, ...)` parameters
- Ensures `outputToken == wallet.baseAsset()` (swaps must result in USDC)

---

### Vault Wrappers (`src/vaults/`)

Vault wrappers serve dual purposes:
1. **Validator**: Implements `IPolicyValidator` for parameter validation
2. **Wrapper**: Handles token approvals and vault interactions

#### ERC4626VaultWrapper (`src/vaults/ERC4626VaultWrapper.sol`)

For Yearn V3, MetaMorpho, and other ERC4626 vaults.

**Roles (AccessControl):**
| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Can grant/revoke other roles (held by TimelockController) |
| `VAULT_ADMIN_ROLE` | Can whitelist vaults (timelocked) |
| `EMERGENCY_ROLE` | Can blacklist vaults instantly |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `addVault(vault)` | VAULT_ADMIN_ROLE | Whitelist a vault (timelocked) |
| `removeVault(vault)` | EMERGENCY_ROLE | Blacklist a vault instantly |
| `validateAction(wallet, target, selector, data)` | View | Check vault is allowed, asset matches |
| `deposit(vault, amount)` | Wallet | Pull tokens, deposit to vault, shares to wallet |
| `withdraw(vault, shares)` | Wallet | Pull shares, redeem from vault, assets to wallet |

---

#### AaveV3VaultWrapper (`src/vaults/AaveV3VaultWrapper.sol`)

For Aave V3 lending pools.

**Roles (AccessControl):**
| Role | Description |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Can grant/revoke other roles (held by TimelockController) |
| `VAULT_ADMIN_ROLE` | Can configure allowed assets (timelocked) |
| `EMERGENCY_ROLE` | Can remove assets instantly |

**Key Functions:**

| Function | Access | Description |
|----------|--------|-------------|
| `addAsset(asset, aToken)` | VAULT_ADMIN_ROLE | Whitelist an asset (timelocked) |
| `removeAsset(asset)` | EMERGENCY_ROLE | Remove an asset instantly |
| `validateAction(wallet, target, selector, data)` | View | Check asset is allowed |
| `deposit(asset, amount)` | Wallet | Supply to Aave, aTokens to wallet |
| `withdraw(asset, amount)` | Wallet | Withdraw from Aave, assets to wallet |

---

### Libraries (`src/lib/`)

#### ERC7579Account (`src/lib/ERC7579Account.sol`)

Base implementation for ERC-7579 modular accounts.

**Key Features:**
- Module registry (`_modules` mapping)
- Multi-EntryPoint support (v0.6, v0.7, v0.8)
- Execution primitives

---

#### AgentWalletStorage (`src/lib/AgentWalletStorage.sol`)

ERC-7201 namespaced storage for safe upgrades.

```solidity
library AgentWalletStorageV1 {
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.v1");

    struct Layout {
        uint256 userAgentIndex;
        address baseAsset;
        address executorModule;
    }
}
```

**Upgrade Pattern:**
- V2 can append fields to V1 struct, OR
- V2 can create new `AgentWalletStorageV2` namespace

---

## Example Flows

### Flow 1: Agent Wallet Creation

**Actors:**
- Admin (has `AGENT_CREATOR_ROLE` on Factory)
- User (EOA that will own the wallet)

**Pre-requisites:**
- Factory deployed with implementation and default executor (Router)

**Sequence:**

```
┌─────────┐          ┌─────────────┐          ┌───────────────┐          ┌────────────┐
│  Admin  │          │   Factory   │          │  ERC1967Proxy │          │   Wallet   │
└────┬────┘          └──────┬──────┘          └───────┬───────┘          └─────┬──────┘
     │                      │                         │                        │
     │ createAgentWallet    │                         │                        │
     │ (user, 0, USDC)      │                         │                        │
     │─────────────────────>│                         │                        │
     │                      │                         │                        │
     │                      │ Compute salt:           │                        │
     │                      │ keccak256(user, 0)      │                        │
     │                      │                         │                        │
     │                      │ new ERC1967Proxy{salt}  │                        │
     │                      │ (impl, initData)        │                        │
     │                      │────────────────────────>│                        │
     │                      │                         │                        │
     │                      │                         │ delegatecall           │
     │                      │                         │ initialize(...)        │
     │                      │                         │───────────────────────>│
     │                      │                         │                        │
     │                      │                         │                        │ Set owner = user
     │                      │                         │                        │ Set baseAsset = USDC
     │                      │                         │                        │ Install Router module
     │                      │                         │                        │
     │                      │                         │<───────────────────────│
     │                      │                         │                        │
     │                      │<────────────────────────│                        │
     │                      │                         │                        │
     │  walletAddress       │                         │                        │
     │<─────────────────────│                         │                        │
     │                      │                         │                        │
```

**Result:**
- New wallet deployed at deterministic address
- User is owner (can withdraw, upgrade)
- Router is installed as executor module
- Wallet ready to receive deposits

**Code Example:**
```solidity
// Admin creates wallet for user
address walletAddr = factory.createAgentWallet(
    userAddress,     // Owner
    0,               // First agent for this user
    USDC_ADDRESS     // Base asset
);

// User can now deposit USDC
IERC20(USDC).transfer(walletAddr, 1000e6);

// Wallet is ready for operator actions
```

---

### Flow 2: User Deposits USDC, Operator Manages Vault Positions

**Actors:**
- User (EOA that owns the wallet)
- Operator (Backend service with operator role on Router)

**Pre-requisites:**
- Agent wallet already created for user
- Router has operator registered
- ERC4626VaultWrapper deployed with Yearn USDC vault whitelisted
- Policy configured to allow wrapper's deposit/withdraw functions

**Sequence:**

```
┌──────┐     ┌────────┐     ┌────────┐     ┌─────────────────┐     ┌────────┐
│ User │     │ Wallet │     │ Router │     │ ERC4626Wrapper  │     │  Vault │
└──┬───┘     └───┬────┘     └───┬────┘     └───────┬─────────┘     └───┬────┘
   │             │              │                  │                   │
   │ USDC.transfer(wallet, 1000)                   │                   │
   │────────────>│              │                  │                   │
   │             │              │                  │                   │
   │             │ [Wallet now holds 1000 USDC]    │                   │
   │             │              │                  │                   │
```

**Step 1: User deposits USDC to their wallet**
```solidity
// User sends 1000 USDC to their agent wallet
IERC20(USDC).transfer(walletAddress, 1000e6);
```

**Step 2: Operator deposits USDC into Yearn vault**

```
┌──────────┐     ┌────────┐     ┌────────┐     ┌────────────────┐     ┌────────┐
│ Operator │     │ Router │     │ Wallet │     │ ERC4626Wrapper │     │  Vault │
└────┬─────┘     └───┬────┘     └───┬────┘     └───────┬────────┘     └───┬────┘
     │               │              │                  │                  │
     │ executeAction │              │                  │                  │
     │ (wallet,      │              │                  │                  │
     │  wrapper,     │              │                  │                  │
     │  deposit(...))│              │                  │                  │
     │──────────────>│              │                  │                  │
     │               │              │                  │                  │
     │               │ Policy.validateAction()        │                  │
     │               │ → wrapper.validateAction()     │                  │
     │               │ → checks vault allowed, asset matches             │
     │               │              │                  │                  │
     │               │ executeFromExecutor            │                  │
     │               │ (wrapper, deposit(vault, amt)) │                  │
     │               │─────────────>│                 │                  │
     │               │              │                 │                  │
     │               │              │ CALL wrapper.deposit(vault, 1000)  │
     │               │              │────────────────>│                  │
     │               │              │                 │                  │
     │               │              │                 │ transferFrom     │
     │               │              │                 │ (wallet→wrapper) │
     │               │              │<────────────────│                  │
     │               │              │                 │                  │
     │               │              │                 │ vault.deposit    │
     │               │              │                 │ (1000, wallet)   │
     │               │              │                 │────────────────>│
     │               │              │                 │                  │
     │               │              │                 │  [Shares minted  │
     │               │              │                 │   to wallet]     │
     │               │              │                 │<────────────────│
     │               │              │<────────────────│                  │
     │               │<─────────────│                 │                  │
     │<──────────────│              │                 │                  │
```

```solidity
// Operator calls router to deposit user's USDC into Yearn vault
router.executeAction(
    walletAddress,
    address(erc4626Wrapper),
    0,  // no ETH value
    abi.encodeCall(ERC4626VaultWrapper.deposit, (yearnVault, 1000e6))
);
// Wallet now holds Yearn vault shares instead of USDC
```

**Step 3: Operator withdraws from vault (e.g., moving to better yield)**

```
┌──────────┐     ┌────────┐     ┌────────┐     ┌────────────────┐     ┌────────┐
│ Operator │     │ Router │     │ Wallet │     │ ERC4626Wrapper │     │  Vault │
└────┬─────┘     └───┬────┘     └───┬────┘     └───────┬────────┘     └───┬────┘
     │               │              │                  │                  │
     │ executeAction │              │                  │                  │
     │ (wallet,      │              │                  │                  │
     │  wrapper,     │              │                  │                  │
     │  withdraw(...)│              │                  │                  │
     │──────────────>│              │                  │                  │
     │               │              │                  │                  │
     │               │ Policy.validateAction()        │                  │
     │               │ → wrapper.validateAction()     │                  │
     │               │              │                  │                  │
     │               │ executeFromExecutor            │                  │
     │               │ (wrapper, withdraw(vault, shares))                │
     │               │─────────────>│                 │                  │
     │               │              │                 │                  │
     │               │              │ CALL wrapper.withdraw(vault, shares)
     │               │              │────────────────>│                  │
     │               │              │                 │                  │
     │               │              │                 │ transferFrom     │
     │               │              │                 │ (wallet→wrapper) │
     │               │              │                 │ [vault shares]   │
     │               │              │<────────────────│                  │
     │               │              │                 │                  │
     │               │              │                 │ vault.redeem     │
     │               │              │                 │ (shares, wallet) │
     │               │              │                 │────────────────>│
     │               │              │                 │                  │
     │               │              │                 │  [USDC sent      │
     │               │              │                 │   to wallet]     │
     │               │              │                 │<────────────────│
     │               │              │<────────────────│                  │
     │               │<─────────────│                 │                  │
     │<──────────────│              │                 │                  │
```

```solidity
// Operator withdraws shares from Yearn vault
// First get the share balance
uint256 shares = IERC20(yearnVault).balanceOf(walletAddress);

router.executeAction(
    walletAddress,
    address(erc4626Wrapper),
    0,
    abi.encodeCall(ERC4626VaultWrapper.withdraw, (yearnVault, shares))
);
// Wallet now holds USDC again (with any yield earned)
```

**Result:**
- User's USDC was deposited to Yearn vault
- Vault shares were held in the wallet (earning yield)
- Operator withdrew back to USDC
- User's wallet now contains original USDC + any yield earned
- At any point, user could call `withdrawTokenToUser()` to withdraw their funds

**Security Notes:**
- Operator can only interact with whitelisted vaults
- Operator cannot withdraw funds to arbitrary addresses
- Operator cannot transfer tokens directly out of wallet
- User retains full control and can withdraw at any time

---

## Security Model

### Actors

| Actor | Description |
|-------|-------------|
| **User** | EOA that owns a wallet. Can withdraw funds and upgrade their wallet. |
| **Operator** | Backend service that executes yield strategies on behalf of wallets. |
| **Platform Admin (Timelocked)** | Manages the Router, Policy, and Vault Wrappers via TimelockController (24h delay). |
| **Emergency Admin** | Can instantly remove operators, policies, or vaults in case of compromise. |
| **Factory Admin** | Can create wallets and update the default implementation. |

---

### Permissions by Contract

#### YieldSeekerAgentWallet

| Action | User (Owner) | Operator | Platform Admin | Anyone |
|--------|:------------:|:--------:|:--------------:|:------:|
| `withdrawTokenToUser()` | ✅ | ❌ | ❌ | ❌ |
| `withdrawEthToUser()` | ✅ | ❌ | ❌ | ❌ |
| `upgradeToAndCall()` | ✅ | ❌ | ❌ | ❌ |
| `installModule()` | ✅ | ❌ | ❌ | ❌ |
| `uninstallModule()` | ✅ | ❌ | ❌ | ❌ |
| `execute()` | via EntryPoint | via EntryPoint | ❌ | ❌ |
| `executeFromExecutor()` | ❌ | via Router | ❌ | ❌ |
| `validateUserOp()` | ❌ | ❌ | ❌ | EntryPoint only |
| Receive deposits | ✅ | ✅ | ✅ | ✅ |

---

#### YieldSeekerAgentWalletFactory

| Action | Role Required | Description |
|--------|---------------|-------------|
| `createAgentWallet()` | `AGENT_CREATOR_ROLE` | Deploy new wallet for a user |
| `setImplementation()` | `DEFAULT_ADMIN_ROLE` | Update implementation for NEW wallets |
| `setDefaultExecutor()` | `DEFAULT_ADMIN_ROLE` | Set Router to auto-install |
| `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Manage access control |

---

#### AgentActionRouter

| Action | Role Required | Timing | Description |
|--------|---------------|--------|-------------|
| `executeAction()` | Operator OR Wallet | Instant | Execute validated action on wallet |
| `setPolicy()` | `POLICY_ADMIN_ROLE` | Timelocked (24h) | Update the Policy contract globally |
| `addOperator()` | `OPERATOR_ADMIN_ROLE` | Timelocked (24h) | Add backend operator |
| `removeOperator()` | `EMERGENCY_ROLE` | Instant | Remove operator immediately |
| `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Timelocked (24h) | Manage access control |

---

#### AgentActionPolicy

| Action | Role Required | Timing | Description |
|--------|---------------|--------|-------------|
| `addPolicy()` | `POLICY_SETTER_ROLE` | Timelocked (24h) | Map (target, selector) → validator |
| `removePolicy()` | `EMERGENCY_ROLE` | Instant | Remove policy rule immediately |
| `validateAction()` | Anyone (view) | N/A | Check if action is permitted |
| `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Timelocked (24h) | Manage access control |

---

#### ERC4626VaultWrapper / AaveV3VaultWrapper

| Action | Role Required | Timing | Description |
|--------|---------------|--------|-------------|
| `addVault()` / `addAsset()` | `VAULT_ADMIN_ROLE` | Timelocked (24h) | Whitelist vaults/assets |
| `removeVault()` / `removeAsset()` | `EMERGENCY_ROLE` | Instant | Blacklist vaults/assets |
| `validateAction()` | Anyone (view) | N/A | Validate deposit/withdraw parameters |
| `deposit()` / `withdraw()` | Wallet (via Router) | Instant | Execute vault operations |
| `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Timelocked (24h) | Manage access control |

---

### What Each Actor Can Achieve

#### User (Wallet Owner)
✅ **CAN:**
- Withdraw any token or ETH to any address
- Upgrade their wallet to any implementation
- Install/uninstall modules (add new capabilities)
- Transfer ownership to another address
- Receive funds from anyone

❌ **CANNOT:**
- Execute operator actions directly (must go through Router)
- Modify Router, Policy, or Wrapper configurations
- Affect other users' wallets

---

#### Operator (Backend Service)
✅ **CAN:**
- Execute actions that pass Policy validation:
  - Deposit to whitelisted vaults
  - Withdraw from whitelisted vaults
  - Claim rewards (only to the wallet itself)
  - Swap tokens (output must be wallet's base asset)
- Sign UserOperations for gas-sponsored transactions

❌ **CANNOT:**
- Withdraw funds to arbitrary addresses
- Approve tokens to non-whitelisted contracts
- Transfer tokens directly
- Upgrade wallet implementations
- Install/uninstall modules
- Call any function not whitelisted in Policy

---

#### Platform Admin (via TimelockController)
✅ **CAN (with 24h delay):**
- Add operators
- Add Policy rules (whitelist new vaults, functions)
- Swap the entire Policy contract
- Whitelist new vaults in wrappers
- Grant/revoke admin roles

❌ **CANNOT:**
- Access user funds directly
- Force-upgrade existing wallets
- Instantly add new operators or policies (24h delay enforced)

---

#### Emergency Admin (EMERGENCY_ROLE)
✅ **CAN (instantly):**
- Remove operators
- Remove policy rules
- Blacklist vaults/assets

❌ **CANNOT:**
- Add new operators or policies
- Access user funds
- Grant or revoke roles
- Execute actions on wallets
- Bypass Policy validation

---

#### Factory Admin
✅ **CAN:**
- Create new wallets for users
- Update default implementation (affects NEW wallets only)
- Change default executor module

❌ **CANNOT:**
- Upgrade existing wallets
- Access funds in any wallet
- Modify Router, Policy, or Wrappers

---

## Deployment

Deployment is automated via Foundry scripts in `script/Deploy.s.sol`.

### Step 1: Deploy All Contracts

```bash
# Set environment variables
export DEPLOYER_PRIVATE_KEY=<your-private-key>
export PROPOSER_ADDRESS=<proposer-multisig>
export EXECUTOR_ADDRESS=<executor-multisig>
export AAVE_V3_POOL=<aave-v3-pool-address>

# Deploy
forge script script/Deploy.s.sol:DeployYieldSeeker --rpc-url <RPC_URL> --broadcast
```

This deploys:
- `YieldSeekerAdminTimelock` (24h delay)
- `AgentActionPolicy`
- `AgentActionRouter`
- `YieldSeekerAgentWallet` (implementation)
- `YieldSeekerAgentWalletFactory`
- `ERC4626VaultWrapper`
- `AaveV3VaultWrapper`
- `MerklValidator`
- `ZeroExValidator`

### Step 2: Schedule Configuration (via Timelock)

```bash
# Additional env vars from Step 1 output
export TIMELOCK_ADDRESS=<deployed-timelock>
export ROUTER_ADDRESS=<deployed-router>
export POLICY_ADDRESS=<deployed-policy>
export FACTORY_ADDRESS=<deployed-factory>
export ERC4626_WRAPPER=<deployed-erc4626-wrapper>
export AAVE_WRAPPER=<deployed-aave-wrapper>
export MERKL_VALIDATOR=<deployed-merkl-validator>
export ZEROEX_VALIDATOR=<deployed-zeroex-validator>
export EMERGENCY_ADDRESS=<emergency-multisig>
export OPERATOR_ADDRESS=<backend-operator>
export USDC_ADDRESS=<usdc-token>
export AUSDC_ADDRESS=<ausdc-token>

# Optional
export YEARN_USDC_VAULT=<yearn-vault>
export METAMORPHO_USDC_VAULT=<metamorpho-vault>
export MERKL_DISTRIBUTOR=<merkl-distributor>
export ZEROEX_EXCHANGE=<zeroex-exchange>

# Schedule all operations
forge script script/Deploy.s.sol:ScheduleTimelockOperations --rpc-url <RPC_URL> --broadcast
```

### Step 3: Execute After 24h Delay

```bash
# After 24 hours have passed
forge script script/Deploy.s.sol:ExecuteTimelockOperations --rpc-url <RPC_URL> --broadcast
```

---

## Upgrade Guide

### Upgrading a Wallet (User Action)

```solidity
// User calls on their wallet
wallet.upgradeToAndCall(
    newImplementationAddress,
    abi.encodeCall(WalletV2.initializeV2, (newParam))
);
```

### Upgrading Policy (Admin Action via Timelock)

```solidity
// Deploy new policy
AgentActionPolicyV2 newPolicy = new AgentActionPolicyV2();

// Configure new policy...

// Schedule update (24h delay)
timelock.schedule(
    router,
    0,
    abi.encodeCall(router.setPolicy, (address(newPolicy))),
    bytes32(0),
    bytes32("updatePolicy"),
    24 hours
);

// After 24h, execute
timelock.execute(...);

// All wallets now use new policy
```

### Adding New Vault Support (via Timelock)

```solidity
// Deploy wrapper
NewVaultWrapper wrapper = new NewVaultWrapper(timelock);

// Grant roles
wrapper.grantRole(VAULT_ADMIN_ROLE, address(timelock));
wrapper.grantRole(EMERGENCY_ROLE, emergencyMultisig);

// Schedule vault whitelist (24h delay)
timelock.schedule(
    wrapper,
    0,
    abi.encodeCall(wrapper.addVault, (vaultAddress)),
    bytes32(0),
    bytes32("addVault"),
    24 hours
);

// After 24h, execute
timelock.execute(...);
```

### Emergency: Removing Compromised Operator

```solidity
// Emergency multisig can act instantly
router.removeOperator(compromisedOperator);  // No delay!
```

// Configure policy
policy.setPolicy(address(wrapper), wrapper.DEPOSIT_SELECTOR(), address(wrapper));
policy.setPolicy(address(wrapper), wrapper.WITHDRAW_SELECTOR(), address(wrapper));

// Operators can now use new vault
```
