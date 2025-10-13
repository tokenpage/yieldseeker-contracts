# Pooled Vault Solution - Share-Based Smart Contract Architecture

This document outlines the **pooled vault approach** where a single smart contract holds one pooled position per vault and tracks each user's allocation using share-based accounting.

---

## Architecture Overview

### Core Concept: Pooled Positions with Share Tracking

Instead of each user having their own position in each vault, this architecture uses:
- **Single contract** holds ONE pooled position per vault provider
- **Share-based accounting** tracks each user's portion of that pooled position
- **Master agent EOA** executes rebalancing operations for all users

```
Multiple Users → YieldSeekerVaultUSDC Contract → Single Position per Vault
                         ↓
              Share-based accounting tracks
              each user's portion of the pool
```

---

## Key Design Decision: Share-Based Accounting

**Critical:** This contract uses **share-based accounting** (like ERC4626) to handle yield accrual properly.

### How It Works

1. **Share Minting (Deposits):**
   - First deposit: shares minted = USDC amount (1:1 ratio)
   - Subsequent deposits: `sharesToMint = (depositAmount * currentTotalShares) / currentTotalValue`
   - As yield accrues in vault, share price increases, but share quantity stays constant

2. **Share Burning (Withdrawals):**
   - `sharesToBurn = (withdrawAmount * currentTotalShares) / currentTotalValue`
   - User receives USDC, contract burns their shares

3. **Yield Accrual:**
   - Vault earns yield → total value increases
   - Share count stays constant → share price increases
   - User's shares represent larger USDC value automatically

4. **Value Calculation:**
   - `userValue = (userShares * totalValue) / totalShares`
   - This automatically includes accrued yield

### Why This Approach

- ✅ Matches current Python implementation (tracks shares from vaults)
- ✅ Automatic yield accrual without manual updates
- ✅ Standard pattern (ERC4626) with battle-tested security
- ✅ Gas efficient (no per-user yield calculations)
- ✅ No rounding errors accumulate over time
- ✅ Lower gas costs per user (shared contract)

---

## Smart Contract Design

### 1. IVaultProvider Interface

Standardized interface that all vault-specific provider contracts must implement:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultProvider {
    /**
     * @notice Deposit USDC into the vault (increases contract's total position)
     * @param amount Amount of USDC to deposit
     * @return success Whether the deposit succeeded
     */
    function deposit(uint256 amount) external returns (bool success);

    /**
     * @notice Withdraw USDC from the vault (decreases contract's total position)
     * @param amount Amount of USDC to withdraw (in USDC terms, not shares)
     * @return actualAmount Actual USDC amount received (may differ due to slippage/fees)
     */
    function withdraw(uint256 amount) external returns (uint256 actualAmount);

    /**
     * @notice Get total USDC value of the contract's position in this vault
     * @return totalValue Total USDC value (includes accrued yield)
     */
    function getTotalValue() external view returns (uint256 totalValue);
}
```

**Key Points:**
- Provider contracts are called by YieldSeekerVaultUSDC only
- Each provider handles vault-specific logic (approvals, share calculations, slippage)
- Amounts are always in USDC terms - providers handle share conversions internally
- Provider manages ONE position for the entire contract

---

### 2. YieldSeekerVaultUSDC Main Contract

Main vault contract that holds user USDC deposits and manages allocations:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVaultProvider.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract YieldSeekerVaultUSDC {
    //═══════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    //═══════════════════════════════════════════════════════════════════════

    IERC20 public immutable USDC;

    // User's USDC balance held in this contract (not yet allocated to vaults)
    mapping(address user => uint256 balance) public userBalance;

    // User's SHARES in each vault provider (NOT USDC amounts)
    // When yield accrues, share value increases, but share quantity stays the same
    mapping(address user => mapping(address provider => uint256 shares)) public userShares;

    // Total shares issued for each provider
    mapping(address provider => uint256 totalShares) public totalShares;

    // Registered vault providers: provider address => vault info
    mapping(address provider => VaultProviderInfo info) public vaultProviders;

    // Master agent EOA that can execute operations on behalf of users
    address public masterAgent;

    // Owner (for admin functions)
    address public owner;

    struct VaultProviderInfo {
        bool isActive;
        string name;           // e.g., "Aave V3 USDC"
        string protocol;       // e.g., "Aave V3"
        uint256 addedAt;
    }

    //═══════════════════════════════════════════════════════════════════════
    // EVENTS
    //═══════════════════════════════════════════════════════════════════════

    event UserDeposit(address indexed user, uint256 amount);
    event UserWithdrawal(address indexed user, uint256 amount);
    event Rebalance(address indexed user, address indexed provider, int256 deltaAmount);
    event VaultProviderRegistered(address indexed provider, string name, string protocol);
    event VaultProviderDeactivated(address indexed provider);

    //═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    //═══════════════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyMasterAgent() {
        require(msg.sender == masterAgent, "Only master agent");
        _;
    }

    //═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    //═══════════════════════════════════════════════════════════════════════

    constructor(address _usdc, address _masterAgent) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_masterAgent != address(0), "Invalid master agent");

        USDC = IERC20(_usdc);
        masterAgent = _masterAgent;
        owner = msg.sender;
    }

    //═══════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    //═══════════════════════════════════════════════════════════════════════

    function registerVaultProvider(
        address provider,
        string calldata name,
        string calldata protocol
    ) external onlyOwner {
        require(provider != address(0), "Invalid provider");
        require(!vaultProviders[provider].isActive, "Already registered");

        vaultProviders[provider] = VaultProviderInfo({
            isActive: true,
            name: name,
            protocol: protocol,
            addedAt: block.timestamp
        });

        emit VaultProviderRegistered(provider, name, protocol);
    }

    function deactivateVaultProvider(address provider) external onlyOwner {
        require(vaultProviders[provider].isActive, "Not active");
        vaultProviders[provider].isActive = false;
        emit VaultProviderDeactivated(provider);
    }

    function setMasterAgent(address newMasterAgent) external onlyOwner {
        require(newMasterAgent != address(0), "Invalid address");
        masterAgent = newMasterAgent;
    }

    //═══════════════════════════════════════════════════════════════════════
    // USER FUNCTIONS
    //═══════════════════════════════════════════════════════════════════════

    function deposit(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");

        USDC.transferFrom(msg.sender, address(this), amount);
        userBalance[msg.sender] += amount;

        emit UserDeposit(msg.sender, amount);
    }

    function withdrawAll() external {
        // Withdraw from all vaults where user has allocations
        address[] memory providers = _getActiveProviders();
        for (uint i = 0; i < providers.length; i++) {
            uint256 shares = userShares[msg.sender][providers[i]];
            if (shares > 0) {
                uint256 currentValue = _getUserAllocationValue(msg.sender, providers[i]);
                _withdrawFromVault(msg.sender, providers[i], currentValue);
            }
        }

        uint256 totalBalance = userBalance[msg.sender];
        require(totalBalance > 0, "No balance");

        userBalance[msg.sender] = 0;
        USDC.transfer(msg.sender, totalBalance);

        emit UserWithdrawal(msg.sender, totalBalance);
    }

    //═══════════════════════════════════════════════════════════════════════
    // MASTER AGENT FUNCTIONS
    //═══════════════════════════════════════════════════════════════════════

    struct TargetAllocation {
        address provider;
        uint256 targetAmount;
    }

    function rebalance(
        address user,
        TargetAllocation[] calldata targetAllocations
    ) external onlyMasterAgent {
        // Validate all providers are active
        for (uint i = 0; i < targetAllocations.length; i++) {
            require(
                vaultProviders[targetAllocations[i].provider].isActive,
                "Inactive provider"
            );
        }

        // Calculate total target allocation
        uint256 totalTarget = 0;
        for (uint i = 0; i < targetAllocations.length; i++) {
            totalTarget += targetAllocations[i].targetAmount;
        }

        uint256 currentTotal = _getTotalPortfolioValue(user);
        require(totalTarget <= currentTotal, "Insufficient funds");

        // Execute rebalancing
        for (uint i = 0; i < targetAllocations.length; i++) {
            address provider = targetAllocations[i].provider;
            uint256 targetAmount = targetAllocations[i].targetAmount;
            uint256 currentAmount = _getUserAllocationValue(user, provider);

            if (targetAmount > currentAmount) {
                uint256 depositAmount = targetAmount - currentAmount;
                _depositToVault(user, provider, depositAmount);
            } else if (targetAmount < currentAmount) {
                uint256 withdrawAmount = currentAmount - targetAmount;
                _withdrawFromVault(user, provider, withdrawAmount);
            }
        }

        // Handle providers not in target (withdraw everything)
        address[] memory allProviders = _getActiveProviders();
        for (uint i = 0; i < allProviders.length; i++) {
            bool inTarget = false;
            for (uint j = 0; j < targetAllocations.length; j++) {
                if (allProviders[i] == targetAllocations[j].provider) {
                    inTarget = true;
                    break;
                }
            }

            if (!inTarget && userShares[user][allProviders[i]] > 0) {
                uint256 currentValue = _getUserAllocationValue(user, allProviders[i]);
                _withdrawFromVault(user, allProviders[i], currentValue);
            }
        }
    }

    //═══════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - SHARE-BASED ACCOUNTING
    //═══════════════════════════════════════════════════════════════════════

    function _depositToVault(
        address user,
        address provider,
        uint256 amount
    ) internal {
        require(userBalance[user] >= amount, "Insufficient balance");

        uint256 totalValue = IVaultProvider(provider).getTotalValue();
        uint256 currentTotalShares = totalShares[provider];

        // Calculate shares to mint
        uint256 sharesToMint;
        if (currentTotalShares == 0) {
            sharesToMint = amount; // First deposit: 1:1 ratio
        } else {
            sharesToMint = (amount * currentTotalShares) / totalValue;
        }

        USDC.approve(provider, amount);
        bool success = IVaultProvider(provider).deposit(amount);
        require(success, "Deposit failed");

        userBalance[user] -= amount;
        userShares[user][provider] += sharesToMint;
        totalShares[provider] += sharesToMint;

        emit Rebalance(user, provider, int256(amount));
    }

    function _withdrawFromVault(
        address user,
        address provider,
        uint256 amount
    ) internal {
        uint256 totalValue = IVaultProvider(provider).getTotalValue();
        uint256 currentTotalShares = totalShares[provider];

        require(currentTotalShares > 0, "No shares in provider");

        // Calculate shares to burn
        uint256 sharesToBurn = (amount * currentTotalShares) / totalValue;
        require(userShares[user][provider] >= sharesToBurn, "Insufficient shares");

        uint256 actualAmount = IVaultProvider(provider).withdraw(amount);

        userShares[user][provider] -= sharesToBurn;
        totalShares[provider] -= sharesToBurn;
        userBalance[user] += actualAmount;

        emit Rebalance(user, provider, -int256(amount));
    }

    function _getTotalPortfolioValue(address user) internal view returns (uint256) {
        uint256 total = userBalance[user];

        address[] memory providers = _getActiveProviders();
        for (uint i = 0; i < providers.length; i++) {
            total += _getUserAllocationValue(user, providers[i]);
        }

        return total;
    }

    function _getUserAllocationValue(
        address user,
        address provider
    ) internal view returns (uint256) {
        uint256 userShareAmount = userShares[user][provider];
        if (userShareAmount == 0) return 0;

        uint256 currentTotalShares = totalShares[provider];
        if (currentTotalShares == 0) return 0;

        uint256 totalValue = IVaultProvider(provider).getTotalValue();

        // userValue = (userShares * totalValue) / totalShares
        return (userShareAmount * totalValue) / currentTotalShares;
    }

    function _getActiveProviders() internal pure returns (address[] memory) {
        // TODO: Implement proper active provider tracking
        address[] memory empty;
        return empty;
    }

    //═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    //═══════════════════════════════════════════════════════════════════════

    function getUserTotalValue(address user) external view returns (uint256) {
        return _getTotalPortfolioValue(user);
    }

    function getUserAllocation(address user, address provider) external view returns (uint256) {
        return _getUserAllocationValue(user, provider);
    }
}
```

---

### 3. Example Vault Provider: ERC4626

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVaultProvider.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

contract ERC4626VaultProvider is IVaultProvider {
    IERC20 public immutable USDC;
    IERC4626 public immutable vault;
    address public immutable yieldSeekerVault;

    constructor(address _usdc, address _vault, address _yieldSeekerVault) {
        USDC = IERC20(_usdc);
        vault = IERC4626(_vault);
        yieldSeekerVault = _yieldSeekerVault;
    }

    modifier onlyYieldSeekerVault() {
        require(msg.sender == yieldSeekerVault, "Only YieldSeekerVault");
        _;
    }

    function deposit(uint256 amount) external onlyYieldSeekerVault returns (bool) {
        USDC.transferFrom(msg.sender, address(this), amount);
        USDC.approve(address(vault), amount);
        vault.deposit(amount, address(this));
        return true;
    }

    function withdraw(uint256 amount) external onlyYieldSeekerVault returns (uint256) {
        uint256 shares = vault.convertToShares(amount);
        uint256 usdcReceived = vault.redeem(shares, yieldSeekerVault, address(this));
        return usdcReceived;
    }

    function getTotalValue() external view returns (uint256) {
        uint256 totalShares = vault.balanceOf(address(this));
        return vault.convertToAssets(totalShares);
    }
}
```

---

### 4. Example Vault Provider: Aave V3

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVaultProvider.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract AaveV3VaultProvider is IVaultProvider {
    IERC20 public immutable USDC;
    IPool public immutable aavePool;
    IERC20 public immutable aUSDC;
    address public immutable yieldSeekerVault;

    constructor(
        address _usdc,
        address _aavePool,
        address _aUSDC,
        address _yieldSeekerVault
    ) {
        USDC = IERC20(_usdc);
        aavePool = IPool(_aavePool);
        aUSDC = IERC20(_aUSDC);
        yieldSeekerVault = _yieldSeekerVault;
    }

    modifier onlyYieldSeekerVault() {
        require(msg.sender == yieldSeekerVault, "Only YieldSeekerVault");
        _;
    }

    function deposit(uint256 amount) external onlyYieldSeekerVault returns (bool) {
        USDC.transferFrom(msg.sender, address(this), amount);
        USDC.approve(address(aavePool), amount);
        aavePool.supply(address(USDC), amount, address(this), 0);
        return true;
    }

    function withdraw(uint256 amount) external onlyYieldSeekerVault returns (uint256) {
        uint256 withdrawn = aavePool.withdraw(address(USDC), amount, yieldSeekerVault);
        return withdrawn;
    }

    function getTotalValue() external view returns (uint256) {
        return aUSDC.balanceOf(address(this));
    }
}
```

---

## Architecture Flow

```
User deposits USDC → YieldSeekerVaultUSDC contract
                          ↓
Backend (master agent) calls rebalance()
                          ↓
Contract calculates deltas and calls vault providers
                          ↓
Vault providers execute vault-specific logic (Aave, Morpho, etc.)
                          ↓
Shares are minted/burned to track user allocations
                          ↓
Yield accrues automatically via share price increase
```

---

## Key Design Challenges & Solutions

### Challenge 1: Yield Accrual

**Problem:** How does user allocation increase from 100 → 105 USDC when vault earns yield?

**Solution:** Share-based accounting
```solidity
// User deposits 100 USDC, receives 100 shares
// Vault earns yield: total value = 1050 USDC, total shares = 1000
// User's value = (100 shares * 1050 USDC) / 1000 shares = 105 USDC ✅
```

### Challenge 2: First Deposit Edge Case

**Problem:** When `totalShares[provider] == 0`, division by zero.

**Solution:**
```solidity
if (currentShares == 0) {
    sharesToMint = amount; // First deposit: 1:1 ratio
} else {
    sharesToMint = (amount * currentShares) / currentTotal;
}
```

### Challenge 3: Gas Costs

**Mitigation:**
- Batch operations where possible
- Optimize storage layout
- Use `calldata` instead of `memory`
- Deploy on Layer 2 for lower costs

---

## Benefits of Pooled Vault Approach

| Benefit | Description |
|---------|-------------|
| **Lower Gas Costs** | Single contract deployment, shared infrastructure |
| **Proven Pattern** | ERC4626-style share accounting is battle-tested |
| **Simpler Upgrades** | One contract to upgrade for all users |
| **Automatic Yield** | Share price increases automatically with vault yield |
| **Fair Distribution** | Proportional yield distribution to all users |

---

## Tradeoffs vs Account Abstraction

| Aspect | Pooled Vault | Account Abstraction |
|--------|--------------|---------------------|
| **Gas per User** | Lower (shared contract) | Higher (per-agent SCA) |
| **Security Model** | Master agent EOA | Whitelist per agent |
| **Complexity** | Share math required | Simpler accounting |
| **Customization** | All users identical | Per-agent rules |
| **Upgradability** | Single upgrade | Single logic upgrade |

---

## Implementation Roadmap

### Phase 1: Core Development (Week 1-2)
- [ ] Implement YieldSeekerVaultUSDC.sol
- [ ] Implement IVaultProvider interface
- [ ] Create ERC4626VaultProvider
- [ ] Create AaveV3VaultProvider
- [ ] Unit tests for share math

### Phase 2: Integration (Week 3-4)
- [ ] Deploy to testnet
- [ ] Integrate with backend
- [ ] Test with real vaults
- [ ] Add more providers (Morpho, Compound)

### Phase 3: Security (Week 5-6)
- [ ] Security audit
- [ ] Reentrancy protection
- [ ] Emergency pause functionality
- [ ] Bug bounty program

### Phase 4: Launch (Week 7+)
- [ ] Deploy to mainnet
- [ ] Migrate existing users
- [ ] Monitor performance
- [ ] Optimize gas usage

---

## Next Steps

1. **Set up development environment** - Hardhat or Foundry
2. **Write comprehensive tests** - Especially share math edge cases
3. **Deploy to testnet** - Base Sepolia for testing
4. **Security audit** - Professional audit before mainnet
5. **Backend integration** - Update Python to call contracts
6. **Migration plan** - Transition from EOA to contracts

---

## Conclusion

The pooled vault approach with share-based accounting provides a gas-efficient, battle-tested solution for managing user funds across multiple DeFi vaults. By leveraging the ERC4626 pattern, we get automatic yield accrual and fair distribution without complex per-user calculations.

**Key Advantages:**
- ✅ Lower gas costs per user
- ✅ Proven share-based accounting pattern
- ✅ Automatic yield tracking
- ✅ Simpler to audit and maintain
- ✅ Works with existing master agent model
