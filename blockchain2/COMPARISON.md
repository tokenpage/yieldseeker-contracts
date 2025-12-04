# YieldSeeker v1 vs v2 Comparison

## Architecture Comparison

### v1 (blockchain/) - Provider Abstraction Pattern

```
┌────────────────────────┐
│  AccessController      │  ← Central registry + access control
│  - Vault Providers []  │
│  - Vault Mappings {}   │
│  - Swap Providers []   │
│  - Operator Roles      │
└───────────┬────────────┘
            │
┌───────────▼────────┐
│ AgentWallet        │
│  - depositToVault  │
│  - withdrawFrom... │
│  - rebalance       │
└────────┬───────────┘
         │
         ├─────► IVaultProvider ──────┐
         │            ▲                │
         │            │                ▼
         │       ┌────┴────────┬──────────┐
         │       │             │          │
         │   ERC4626      AaveV3    MorphoBlue
         │   Provider     Provider   Provider
         │       │             │          │
         │       ▼             ▼          ▼
         │    Yearn        Aave V3     Morpho
         │    Vault         Pool       Vault
         │
         └─────► ISwapProvider ──────┐
                      ▲               │
                      │               ▼
                 ┌────┴────────┬──────────┐
                 │             │          │
             Uniswap      Aerodrome   Balancer
             Provider     Provider    Provider
```

**Pros:**
- ✅ Clean abstraction layers
- ✅ Protocol-agnostic interface
- ✅ Easy to add new providers
- ✅ Type-safe contract calls

**Cons:**
- ❌ Must deploy new provider for each protocol
- ❌ Limited flexibility (interface must cover all cases)
- ❌ More contracts = more gas
- ❌ Backend must know which provider to use

---

### v2 (blockchain2/) - Calldata Validation Pattern

```
┌────────────────────────────┐
│  AccessController          │  ← Registry + access control
│  - Approved Vaults []      │
│  - Approved SwapProviders []│
│  - Operator Roles          │
└───────────┬────────────────┘
            │
┌───────────▼────────┐
│ AgentWallet        │
│  executeCall()     │───┐
│  executeBatch()    │   │
└────────────────────┘   │
                         │
          Backend generates calldata
          directly for each protocol
                         │
                         ▼
          ┌──────────────────────────┐
          │  Validation Logic:       │
          │  1. Target approved?     │
          │  2. ERC20 op safe?       │
          │     - approve() to ok?   │
          │     - transfer() to ok?  │
          └──────────────────────────┘
                         │
                         ▼
          Execute: Yearn, Aave, Morpho,
                   Uniswap, Aerodrome, etc.
                   (any protocol directly)
```

**Pros:**
- ✅ Maximum flexibility - call any approved protocol
- ✅ No provider contracts needed
- ✅ Backend has full control
- ✅ Easy to support new protocols (just approve address)
- ✅ Less gas overhead

**Cons:**
- ❌ Backend must generate correct calldata
- ❌ Backend must know each protocol's interface
- ❌ More backend complexity

---

## Security Model Comparison

### v1 Security:
```solidity
// Operator calls specific functions
agentWallet.depositToVault(vault, amount)
  → operator.getVaultProvider(vault)  // Validated
    → provider.deposit(vault, token, amount)  // Type-safe
```

**Security guarantees:**
- Only approved providers can be called
- Provider interface enforces correct behavior
- No way to call arbitrary functions

### v2 Security:
```solidity
// Operator sends calldata
agentWallet.executeCall(target, 0, calldata)
  → _validateCall(target, calldata)
    → isContractApproved(target)?  // Check 1
    → isERC20? → validateERC20Call()  // Check 2
      → transfer/approve to approved address only
  → target.call(calldata)  // Execute
```

**Security guarantees:**
- Only approved contracts can be called
- ERC20 operations validated (prevent theft)
- User can always withdraw (owner functions)

**Both are secure** if:
- v1: Providers are correctly implemented
- v2: Contract approvals are correctly maintained

---

## Code Example Comparison

### Deposit to Yearn Vault

**v1 Backend:**
```javascript
// Backend finds the right provider
const provider = await getVaultProvider(vaultAddress)

// Call AgentWallet function
await agentWallet.depositToVault(vaultAddress, amount)

// Contract handles provider lookup and call
```

**v2 Backend:**
```javascript
// Backend generates calldata directly
const yearnVault = new ethers.Contract(vaultAddress, YearnVaultABI)
const calldata = yearnVault.interface.encodeFunctionData(
  'deposit',
  [amount, agentWallet]  // Yearn-specific params
)

// Send calldata to execute
await agentWallet.executeCall(vaultAddress, 0, calldata)
```

---

### Swap on Uniswap

**v1 Backend:**
```javascript
// Must have a swap provider for Uniswap
const swapProvider = await getSwapProvider(uniswapAddress)

await agentWallet.swapTokens(
  swapProvider,
  tokenIn,
  tokenOut,
  amountIn,
  minAmountOut
)

// Provider knows how to call Uniswap
```

**v2 Backend:**
```javascript
// Backend generates Uniswap calldata
const router = new ethers.Contract(routerAddress, UniswapRouterABI)
const calldata = router.interface.encodeFunctionData(
  'swapExactTokensForTokens',
  [amountIn, minAmountOut, [tokenIn, tokenOut], agentWallet, deadline]
)

await agentWallet.executeCall(routerAddress, 0, calldata)
```

---

## When to Use Each

### Use v1 (Provider Pattern) if:
- ✅ You want maximum type safety
- ✅ You want contracts to be self-documenting
- ✅ You have limited set of protocols
- ✅ You want to minimize backend complexity
- ✅ You're okay with deploying providers

### Use v2 (Calldata Pattern) if:
- ✅ You want maximum flexibility
- ✅ You need to support many protocols quickly
- ✅ Your backend can handle protocol interfaces
- ✅ You want minimal contract footprint
- ✅ You want easier protocol additions (no new contracts)

---

## Recommendation

For **YieldSeeker**, v2 is likely better because:

1. **Yield protocols change frequently** - v2 adapts faster
2. **Many protocols to support** - v2 doesn't need new contracts
3. **Backend already complex** - v2 gives backend full control
4. **Gas costs** - v2 has fewer proxy layers
5. **Agent autonomy** - v2 allows agents to interact with any approved protocol

The security model is equally strong in both versions.
