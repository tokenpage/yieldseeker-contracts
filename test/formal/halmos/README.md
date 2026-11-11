# Halmos symbolic checks

These tests run with Halmos 0.3.3 against the repository's Foundry configuration (solc 0.8.38, `via_ir = true`). They use Foundry-style `check_` names; `forge test` does not execute those checks. Each run is scoped to one contract to keep solver load bounded. On this Mac, `gtimeout` from Homebrew coreutils supplies the process wall-clock limit.

## Run commands and observed runtimes

Run from this worktree; replace `--root` if the checkout moves.

```sh
gtimeout 600 halmos --root /Users/krishan/Projects/yieldseeker-contracts-verification-halmos --function check_ --match-contract '^FeeAccountingHalmos$' --loop 2 --solver-timeout-branching 5s --solver-timeout-assertion 60s --storage-layout solidity
```

Fee checks: **98.75s**, 7 passed.

```sh
gtimeout 600 halmos --root /Users/krishan/Projects/yieldseeker-contracts-verification-halmos --function check_ --match-contract '^BorrowSwapHalmos$' --loop 2 --solver-timeout-branching 5s --solver-timeout-assertion 60s --storage-layout solidity
```

Borrow-swap checks: **20.22s**, 3 passed.

```sh
gtimeout 600 halmos --root /Users/krishan/Projects/yieldseeker-contracts-verification-halmos --function check_ --match-contract '^UserOpSignatureHalmos$' --loop 2 --solver-timeout-branching 5s --solver-timeout-assertion 60s --storage-layout solidity
```

Signature checks: **0.17s**, 6 passed.

```sh
gtimeout 180 halmos --root /Users/krishan/Projects/yieldseeker-contracts-verification-halmos --function check_ --match-contract '^PriceOracleHalmos$' --loop 2 --solver-timeout-branching 2s --solver-timeout-assertion 10s --storage-layout solidity
```

Oracle checks: **73.75s**, 3 passed. The assertion timeout is per solver assertion; `gtimeout` is the overall wall-clock limit.

## Coverage and bounds

- **Property 2 — cost basis and yield fee:** `check_property2_fullWithdrawalReleasesAllRemainingBasis`, `check_property2_partialWithdrawalReleasesOnlyItsShareOfBasis`, `check_property2_aLossNeverCreatesYieldFee`, and `check_property2_withdrawalWithoutCostBasisTreatsAllOutputAsYield` call the actual module release logic with symbolic `uint128` amounts. The full/partial/loss cases require `heldBefore > 0`; the separate no-basis check covers zero basis, including `heldBefore == 0`. `check_property2_yieldFeeNeverExceedsRoundedRate` exercises the actual fee module and proves the fee equals (and therefore is no greater than) the rounded-up formula for symbolic `uint8` yield and `uint8` rate (0–255 bps).
- **Property 5 — borrow fee monotonicity:** `check_property5_pendingBorrowFeeIsMonotonicInDebt` compares symbolic `uint8` debts (0–255) at a fixed timestamp and 100% plan rate. `check_property5_pendingBorrowFeeNeverFallsAfterOneMoreSecondAtFixedDebt` checks every symbolic elapsed duration 0–255 against the next second, at fixed debt `1e18` and the same rate. Both call the actual `_pendingFee` through a minimal harness. These bounded, single-axis proofs do not cover every debt/time combination.
- **Property 6 — UserOp signature decision:** the owner, operator, symbolic signer, selector, and paymaster rules are checked for every 4-byte selector and 20-byte paymaster address; short-data checks use symbolic 3-byte call data and 19-byte paymaster data. ECDSA recovery itself is abstracted as a supplied recovered-signer address in `validateRecoveredSigner`, which mirrors the ECDSA decision branches of `_validateUserOpSignature`; this does **not** prove ECDSA cryptography or the `ecrecover` precompile. `check_property6_erc1271OwnerCanApproveShortNonAdapterOperation` separately calls the actual `_validateUserOpSignature` with a mock ERC-1271 owner that always returns the magic value.
- **Property 11 — borrow swap result formula:** the three `check_property11_...` checks call the actual `checkSwapResult`. Sold amount, bought amount, held balance, and oracle quote are symbolic `uint256`; debt is symbolic `uint240` so the buffered multiplication fits `uint256`. Minimal oracle, token, and fee-module mocks supply the symbolic quote, held amount, and debt. The checks cover the base-asset swap price floor (ceil, 500 bps slippage) and the buffered debt ceiling (300 bps). `checkSwap` token-direction / reward-sale rules are not covered here.
- **Property 13 — decimal scaling and monotonicity:** the actual `PriceOracle.quote` is checked with equal $1 mock prices, 6-decimal and 18-decimal tokens. Six-to-eighteen scaling covers symbolic amounts 0–255; eighteen-to-six covers symbolic amounts through `2^40-1`, including nonzero whole-unit quotes. The adjacent-step check proves no decrease from each amount 0–254 to the next; by transitivity this covers the `uint8` domain. Other decimal pairs, varying prices, overflow at realistic price ranges, stale-feed rejection, and sequencer rejection are not proven here.

**Property 3 (withdrawal splitting) is not proven.** An isolated check of the actual release logic, narrowed to `uint8` amounts and set up outside the symbolic test, still exceeded a 120-second wall-clock limit. It was removed from the final `check_` suite; no result is claimed.
