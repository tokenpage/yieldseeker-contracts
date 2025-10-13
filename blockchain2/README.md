# YieldSeeker Smart Contracts v2

Alternative implementation with simplified architecture:

## Key Differences from v1:

### 1. **No Provider Abstractions**
- No `IVaultProvider` or provider contracts
- Backend generates calldata directly for each protocol
- More flexible, less contract overhead

### 2. **Security Through Validation**
- Registry of approved contracts (vaults & swaps)
- ERC20 operation validation prevents fund theft
- No arbitrary calls - only to approved contracts

### 3. **Calldata-Driven**
Backend responsibility:
- Generate protocol-specific calldata
- Know each vault/swap interface
- Handle all protocol quirks

Contract responsibility:
- Validate target is approved
- Check ERC20 operations are safe
- Execute the call

## Architecture

```
┌─────────────────┐
│  ContractRegistry│  ← Admin approves vaults & swaps
└────────┬────────┘
         │
┌────────▼────────┐
│ AccessController│  ← Manages operators & pause
└────────┬────────┘
         │
┌────────▼────────┐
│  AgentWallet    │  ← Executes validated calldata
│  - executeCall  │     Only to approved contracts
│  - executeBatch │     ERC20 ops validated
└─────────────────┘
```

## Security Model

### What Operator CAN Do:
- ✅ Call approved vault contracts (deposit, withdraw, etc.)
- ✅ Call approved swap contracts (swap tokens)
- ✅ Approve baseAsset to approved contracts
- ✅ Transfer baseAsset to approved contracts

### What Operator CANNOT Do:
- ❌ Call unapproved contracts
- ❌ Transfer baseAsset to arbitrary addresses
- ❌ Approve baseAsset to arbitrary addresses
- ❌ Override user's ability to withdraw

### User Always Can:
- ✅ Withdraw baseAsset to any address (owner only)
- ✅ Withdraw ETH to any address (owner only)
- ✅ Works even if operator is malicious

## Example Usage

### Backend generates deposit calldata:
```javascript
// For Yearn vault
const calldata = vault.interface.encodeFunctionData('deposit', [amount, agentWallet])

await agentWallet.executeCall(vaultAddress, 0, calldata)
```

### Backend generates swap calldata:
```javascript
// For Uniswap
const calldata = router.interface.encodeFunctionData('swapExactTokensForTokens', [
  amountIn, amountOutMin, path, agentWallet, deadline
])

await agentWallet.executeCall(routerAddress, 0, calldata)
```

### Backend generates batch:
```javascript
const calls = [
  { target: vault1, value: 0, data: withdrawCalldata },
  { target: vault2, value: 0, data: depositCalldata }
]

await agentWallet.executeBatch(calls)
```

## Deployment

```bash
forge build
forge test
```

## Benefits

1. **Simpler contracts** - No provider layer
2. **More flexible** - Backend can call any approved protocol
3. **Secure** - Strict validation prevents fund theft
4. **Gas efficient** - No extra proxy layers
5. **Easier to extend** - Just approve new contracts, no new providers needed
