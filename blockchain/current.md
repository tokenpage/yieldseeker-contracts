# Smart Contract Migration Plan - Yield Seeker

## Executive Summary

This document outlines the plan to migrate Yield Seeker from the current architecture where agents directly control funds in their wallets to a new architecture where user deposits are held in a smart contract that delegates vault operations to the agent wallets.

## Current Architecture Analysis

### How it Works Now

1. **User Deposits**
   - Users deposit USDC directly to their agent's wallet address
   - The agent wallet is an **EOA (Externally Owned Account)** created via Coinbase CDP API
   - Private keys are managed by Coinbase CDP (not stored locally)
   - Agent wallets can be delegated to Coinbase Smart Wallet for easier transaction execution
   - Backend signs transactions via Coinbase CDP API using the stored private keys

2. **Vault Operations**
   - Each vault (Aave, Compound, Morpho, Euler, Spark, Tokemak, Revert, YO, etc.) has its own provider implementation
   - Providers implement the `YieldProvider` interface with methods:
     - `get_deposit_calls()` - Returns encoded calls to deposit to vault
     - `get_withdraw_calls()` - Returns encoded calls to withdraw from vault
     - `get_position()` - Gets current position in vault
     - `list_claimable_rewards()` - Lists claimable rewards
   - Agent wallets execute these calls directly to interact with vaults

3. **Transaction Flow**
   - `AutoseekManager` analyzes yield options and decides optimal allocation
   - `TransactionManager.make_calls_transaction()` executes the deposit/withdraw calls
   - Backend signs transactions using agent's EOA via Coinbase CDP API
   - Agent EOA directly calls vault contracts (approve, deposit, withdraw, etc.)
   - Each vault provider handles approval and transaction encoding independently
   - Transactions are tracked in `AgentWalletTransaction` table

4. **Tracking & Accounting**
   - `WalletManager` tracks deposits via `AgentWalletDeposit` (user deposits to agent)
   - `WalletManager` tracks all token movements via `AgentWalletMovement`
   - Daily snapshots calculate net deposits, yields, and APY
   - Position tracking determines balances across vaults

### Agent EOA Management

**Important:** Agent wallets are **EOAs (Externally Owned Accounts)**, not smart contracts.

**How It Works:**
1. When a user creates an agent, `create_agent()` calls `coinbaseCdpClient.create_eoa()`
2. Coinbase CDP API creates a new EOA and stores the private key securely
3. The EOA address is stored in `tbl_agent_wallets`
4. Backend never has direct access to private keys - they're managed by Coinbase CDP
5. To execute transactions, backend calls `coinbaseCdpClient.sign_transaction()` which:
   - Sends the unsigned transaction to Coinbase CDP API
   - Coinbase CDP signs with the stored private key
   - Returns the signed transaction
   - Backend broadcasts the signed transaction to the network

**Key Files:**
- `api/agent_hack/external/coinbase_cdp_client.py` - Coinbase CDP API client
- `api/agent_hack/user_manager.py::create_agent()` - Creates EOA via CDP
- `api/agent_hack/transaction_manager.py` - Signs transactions via CDP

**Security Model:**
- Private keys never leave Coinbase CDP infrastructure
- Backend authenticates to CDP using API keys (wallet secret + API key)
- Each transaction requires backend authentication to CDP
- Coinbase CDP can optionally delegate EOA to Coinbase Smart Wallet for additional features

