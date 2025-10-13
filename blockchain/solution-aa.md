# AI Agent Smart Wallet Architecture

Architecture for secure, autonomous AI agent wallets using smart contracts to eliminate EOA risks.

## 1. Core Objectives

| Goal | Implementation |
|------|---------------|
| **Security** | Smart contract constrains backend operations - funds can only go to approved vaults or user |
| **Scalability** | Single delegated logic contract serves all agents (minimal proxy pattern) |
| **User Control** | Users have direct emergency withdrawal access, bypassing all backend systems |
| **Key Management** | Centralized operator contract manages all backend keys globally |

---

## 2. Architecture Overview

### Smart Contract Account Pattern

Each agent is a smart contract wallet that:
- Holds assets and vault positions
- Delegates logic to shared `AgentController`
- Only accepts calls from `YieldSeekerAccessController`
- Gives users direct emergency access

### Three-Layer Security

```
Backend EOAs → YieldSeekerAccessController → Agent Wallets
(keys)         (authorization)        (funds)
```

1. **YieldSeekerAccessController** - Manages which backend keys are authorized
2. **VaultRegistry** - Defines which vaults are approved
3. **SwapRegistry** - Defines which swap providers are approved
4. **AgentController** - Enforces only specific operations

---

## 3. Core Security: Constrained Operations

### The Constraint Model

**Problem**: Autonomous agents need backend keys, but keys must not enable theft.

**Solution**: Backend can ONLY call specific functions on approved vaults/swaps:
- `rebalance(actions[])` - withdraw from vaults, deposit to vaults
- `depositToVault(vault, amount)`
- `withdrawFromVault(vault, amount)`
- `claimRewards(vault)`
- `swapTokens(provider, tokenIn, tokenOut, amountIn, minOut)` - swap via approved providers
- `withdrawToUser(token, amount)` - sends to user only

### What Backend Keys CANNOT Do

❌ Transfer to arbitrary addresses
❌ Call `approve()` for attacker contracts
❌ Interact with non-registered vaults
❌ Modify vault registry
❌ Prevent user emergency withdrawal

---

## 4. Key Components

### AgentWallet (Minimal Proxy)
- Ultra-lightweight proxy (EIP-1167)
- Delegates all calls to AgentController implementation
- Each user deploys their own
- Contains user's USDC balance

### AgentController (Implementation)
- Contains all wallet logic
- Enforces security constraints:
  - VaultRegistry whitelist check
  - SwapRegistry whitelist check
  - User-only withdrawals
  - YieldSeekerAccessController authorization
- Handles deposits, vault operations, swaps, withdrawals
- Upgradeable pattern (but proxy itself never changes)

### YieldSeekerAccessController
- **Single authorization gateway** for all backend operations
- Maps backend EOA addresses → authorization status
- Provides specific functions agents can call:
  - `depositToVault(agent, vault, amount)`
  - `withdrawFromVault(agent, vault, amount)`
  - `claimRewards(agent, vault)`
  - `swapTokens(agent, provider, tokenIn, tokenOut, amountIn, minOut)`
  - `rebalance(agent, actions[])` - batch operations
- **Key rotation**: 1-2 txs to rotate keys globally across ALL agents
- **Emergency pause**: 1 tx pauses all agent operations
- Platform controlled, not user controlled

### VaultRegistry
- Platform-managed list of approved vault providers
- Each vault provider is a contract implementing `IVaultProvider`
- Prevents agents from interacting with malicious vaults
- Admin can add/remove vault providers

### SwapRegistry
- Platform-managed list of approved swap providers
- Each swap provider is a contract implementing `ISwapProvider`
- Maps swap router addresses → ISwapProvider implementations
- Prevents agents from interacting with malicious DEXes
- Admin can add/remove swap providers

### IVaultProvider Interface
```solidity
interface IVaultProvider {
    function deposit(address token, uint256 amount) external returns (uint256 shares);
    function withdraw(uint256 shares) external returns (uint256 amount);
    function claimRewards() external returns (address[] tokens, uint256[] amounts);
    function getShareValue(uint256 shares) external view returns (uint256);
}
```

### ISwapProvider Interface
```solidity
interface ISwapProvider {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);

    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}
```

### Swap Provider Implementations
- **UniswapSwapProvider**: Wraps Uniswap V3 router
- **AerodromeSwapProvider**: Wraps Aerodrome router
- **VelodromeSwapProvider**: Wraps Velodrome router
- Each provider translates ISwapProvider calls to protocol-specific router calls

### AgentWalletFactory
- Deploys new AgentWallet proxies
- Initializes with user's address
- Links to current AgentController implementation

---

## 5. Complete Autonomous Flow (With Reward Swaps)

### Example: Rebalance from Morpho → Aerodrome + Claim & Swap Rewards

1. **Backend Analysis** (off-chain):
   - Detects Morpho has better APY than current vault
   - Checks agent's AERO reward balance (from previous claims)
   - Queries swap quotes for AERO → USDC:
     ```python
     # Off-chain quote discovery
     quotes = []
     for provider in swap_providers:
         quote = provider.get_quote(AERO, USDC, aero_balance)
         quotes.append((provider, quote))

     # Select best quote
     best_provider, best_quote = max(quotes, key=lambda x: x[1])
     min_amount_out = best_quote * 0.99  # 1% slippage tolerance
     ```

2. **Backend Executes Rebalance** (on-chain):
   ```solidity
   // Via YieldSeekerAccessController.rebalance()
   Action[] memory actions = [
       // Step 1: Swap AERO rewards → USDC
       Action({
           actionType: ActionType.SWAP,
           vault: address(0),
           swapProvider: aerodromeSwapProvider,
           tokenIn: AERO,
           tokenOut: USDC,
           amount: aero_balance,
           minAmountOut: min_amount_out
       }),

       // Step 2: Withdraw from current vault
       Action({
           actionType: ActionType.WITHDRAW,
           vault: currentVault,
           amount: all_shares
       }),

       // Step 3: Deposit to new vault
       Action({
           actionType: ActionType.DEPOSIT,
           vault: morphoVault,
           amount: total_usdc_balance  // includes swapped AERO
       })
   ];

   operator.rebalance(agentAddress, actions);
   ```

3. **AgentController Execution**:
   - Validates operator is authorized
   - For swap action:
     - Checks swapProvider is in SwapRegistry ✓
     - Calls `swapProvider.swap(AERO, USDC, amount, minOut, agent)`
     - Receives USDC to agent wallet
   - For withdraw action:
     - Checks vault is in VaultRegistry ✓
     - Calls `vault.withdraw(shares)`
     - Receives USDC to agent wallet
   - For deposit action:
     - Checks vault is in VaultRegistry ✓
     - Approves USDC to vault
     - Calls `vault.deposit(USDC, amount)`
     - Receives vault shares

4. **Result**:
   - AERO rewards converted to USDC (maximizing reinvestment)
   - Agent fully rebalanced to higher-yield vault
   - All done in 1 transaction
   - User maintains full custody

---

## 6. Security Model

### Three-Layer Defense

1. **YieldSeekerAccessController** - Manages which backend keys are authorized
   - Platform can rotate keys in 1-2 txs
   - Platform can pause all operations with 1 tx
   - Provides ONLY specific functions (no arbitrary executeOnAgent)

2. **VaultRegistry** - Defines which vaults are approved
   - Platform controls which protocols agents can use
   - Prevents malicious vault contracts
   - Each vault must implement IVaultProvider interface

3. **SwapRegistry** - Defines which swap routers are approved
   - Platform controls which DEXes agents can use
   - Prevents malicious swap contracts
   - Each swap router must have ISwapProvider wrapper

4. **AgentController** - Enforces only specific operations
   - User withdrawals go ONLY to user address
   - All vault operations checked against VaultRegistry
   - All swap operations checked against SwapRegistry
   - No arbitrary external calls

### Gas Sponsorship Model

**Note**: This architecture already provides gas sponsorship without needing EIP-4337!

- Backend operator EOA submits all transactions (depositToVault, withdrawFromVault, etc.)
- **Operator EOA pays all gas fees** - agent wallets don't need ETH
- Users pay zero gas - they only hold USDC in their agent wallets
- This is functionally identical to EIP-4337 paymasters, but:
  - ✅ ~100k gas cheaper per transaction (no EntryPoint/bundler overhead)
  - ✅ No complex UserOperation infrastructure
  - ✅ No paymaster validation logic needed
  - ✅ Simpler architecture = smaller attack surface

**Why EIP-4337 is NOT needed**:
- EIP-4337 is designed for user-facing wallets where users sign transactions client-side
- Our agents are backend-controlled autonomous systems
- Operator already signs and submits all transactions → automatic gas sponsorship
- Adding EIP-4337 would only increase costs and complexity for no benefit

**Future consideration**: Only migrate to EIP-4337 if users need direct control over agents without backend intermediary (e.g., user clicks "rebalance" → wallet signs → paymaster sponsors).

### Hybrid Security Pattern

**Operator has explicit functions** (type-safe, clear intent):
```solidity
function depositToVault(address agent, address vault, uint256 amount) external;
function withdrawFromVault(address agent, address vault, uint256 shares) external;
function swapTokens(address agent, address provider, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) external;
function rebalance(address agent, Action[] calldata actions) external;
```

**Agent validates caller** (defense in depth):
```solidity
modifier onlyOperator() {
    require(msg.sender == yieldSeekerOperator, "only operator");
    _;
}

function depositToVault(address vault, uint256 amount) external onlyOperator {
    require(vaultRegistry.isApproved(vault), "vault not approved");
    // ...
}

function swapTokens(address provider, ...) external onlyOperator {
    require(swapRegistry.isApproved(provider), "swap provider not approved");
    // ...
}
```

**Why hybrid?**
- Explicit functions = Clear audit trail, type safety, no encoding bugs
- Agent validation = Defense in depth, prevents operator compromise
- Registry checks = Platform controls which protocols are safe

### Critical Security Consideration

⚠️ **Registry Admin Key = God Mode**

The account that can add vault providers / swap providers to the registries can steal all funds:

**VaultRegistry attack:**
1. Deploy malicious VaultProvider that transfers all deposits to attacker
2. Add it to VaultRegistry
3. Call `depositToVault()` on all agents with malicious vault
4. All USDC is stolen

**SwapRegistry attack:**
1. Deploy malicious SwapProvider that transfers tokens to attacker instead of swapping
2. Add it to SwapRegistry
3. Call `swapTokens()` on all agents with malicious provider
4. All tokens are stolen

**Mitigations:**
- Registry admin should be multi-sig (e.g., Gnosis Safe with 3-of-5)
- Timelock on registry changes (e.g., 48-hour delay)
- Public notification when new providers are added
- Community review of provider contracts before approval
- Consider immutable list of initial "safe" providers

---

## 7. Deployment Pattern

### Minimal Proxy (EIP-1167)

Each agent wallet deployed as ~200 byte proxy:
```
AgentWallet (proxy) → AgentController (implementation)
```

**Why EIP-1167 over EIP-4337**:
- ✅ Gas efficient deployment (~45k gas vs ~500k for 4337)
- ✅ All agents share single logic contract
- ✅ Easy upgrades (deploy new controller, migrate agents)
- ✅ Simpler security model - easier to audit
- ✅ Backend operator already provides gas sponsorship (see Security Model section)
- ✅ Deterministic CREATE2 addresses work perfectly for cross-chain consistency

**EIP-4337 NOT needed because**:
- Our agents are backend-controlled, not user-facing wallets
- Operator EOA already pays all gas (automatic sponsorship)
- No need for UserOperations, bundlers, or paymasters
- Would add ~100k gas overhead per transaction for no benefit
- Only consider 4337 if users need direct control without backend

---

## 8. Why This Architecture

### Individual Positions Required

Cannot use pooled vault because:
- Off-chain rewards (AERO, MORPHO) need individual attribution
- Each agent must hold own vault shares for accurate reward claims

### Operator Pattern Required

Without operator, to rotate a compromised key:
- ❌ Must call `rotateKey()` on 10,000 agent contracts
- ✅ With operator: `removeOperator()` (1 tx, all agents)

### Vault Constraints Required

Without constraints:
- ❌ Backend could call any function on whitelisted address
- ❌ `approve()` to attacker, `transferFrom()` to steal
- ✅ With constraints: Only deposit/withdraw/claim on registered vaults

---

## 9. Architecture Diagram

```
┌─────────────────────────────────────────┐
│   Backend EOAs                          │
│   - Production (daily ops)              │
│   - Emergency (break-glass)             │
│   - Dev (testnet)                       │
└────────────────┬────────────────────────┘
                 ↓
┌─────────────────────────────────────────┐
│   YieldSeekerAccessController                   │
│   - Authorized operator whitelist       │
│   - depositToVault()                    │
│   - withdrawFromVault()                 │
│   - swapTokens()                        │
│   - rebalance()                         │
│   - pauseAllAgents()                    │
└────────────────┬────────────────────────┘
                 ↓
        ┌────────┴────────┐
        ↓                 ↓
┌─────────────────┐  ┌─────────────────┐
│  VaultRegistry  │  │  SwapRegistry   │
│  - Approved     │  │  - Approved     │
│    vaults       │  │    swap routers │
└────────┬────────┘  └────────┬────────┘
         ↓                    ↓
┌────────────────┐  ┌──────────────────┐
│ Vault Providers│  │ Swap Providers   │
│ - AaveProvider │  │ - UniswapSwap    │
│ - MorphoProvider│  │ - AerodromeSwap  │
│ - IVaultProvider│  │ - ISwapProvider  │
└────────┬────────┘  └────────┬─────────┘
         ↑                    ↑
         └────────┬───────────┘
                  ↓
┌─────────────────────────────────────────┐
│   AgentController                       │
│   - rebalance()                         │
│   - depositToVault()                    │
│   - withdrawFromVault()                 │
│   - swapTokens()                        │
│   - claimRewards()                      │
│   - emergencyWithdraw()                 │
└────────────────┬────────────────────────┘
                 ↑
        ┌────────┴────────┐
        ↓                 ↓
┌──────────────┐  ┌──────────────┐
│ AgentWallet  │  │ AgentWallet  │
│ (User A)     │  │ (User B)     │
│ - Proxy      │  │ - Proxy      │
│ - Delegatecall│  │ - Delegatecall│
└──────────────┘  └──────────────┘
```

---

## 10. Key Insights

1. **Accept backend keys exist** - don't try to eliminate them, constrain what they can do
2. **Smart contract is security boundary** - not key custody
3. **Users always have escape hatch** - emergencyWithdraw() bypasses all backend systems
4. **Centralize what makes sense** - operator pattern for keys, registry for vaults/swaps
5. **Minimize attack surface** - no arbitrary calls, only specific vault/swap operations
6. **Registry admin is highest privilege** - VaultRegistry/SwapRegistry admin key can add malicious providers; protect above all else
7. **Off-chain quote discovery** - Backend queries all DEXes off-chain, selects best quote, executes on-chain with slippage protection

---

## The Security Guarantee

Even with backend fully compromised:
- Maximum damage: suboptimal rebalancing or unfavorable swaps (annoyance)
- Not possible: fund theft to attacker
- User recovery: always available via emergencyWithdraw()

**This is the right model for autonomous DeFi agents.**
