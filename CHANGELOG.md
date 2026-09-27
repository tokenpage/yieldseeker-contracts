# Changelog

## Unreleased

### Agent wallet V2

- Added `AWKAgentWalletV2` and `YieldSeekerAgentWalletV2` with EntryPoint-relayed owner actions.
- Blocklist management, ERC20/ETH withdrawals, synchronization, and UUPS upgrades can be paymaster-relayed; owner signatures remain required.
- Operator signatures remain limited to adapter execution.
- Added `AgentWalletStorageV2` as an explicit facade over the unchanged V1 storage layout.
- Existing V1 wallets retain their state when upgraded; V1 implementation behavior remains unchanged.
