# Halmos symbolic checks

These tests run with Halmos 0.3.3 against the repository's Foundry configuration (solc 0.8.38, `via_ir = true`). They use Foundry-style `check_` names; `forge test` does not execute them. Each suite runs on its own to keep solver load bounded.

## Running

From the contracts root (`uv tool install halmos` once):

```sh
make prove-halmos
```

| Suite | Checks | Time on an M-series Mac |
| --- | ---: | ---: |
| `FeeAccountingHalmos` | 7 | 107s |
| `BorrowSwapHalmos` | 3 | 20s |
| `UserOpSignatureHalmos` | 1 | <1s |
| `PriceOracleHalmos` | 3 | 162s |

## Coverage and bounds

- **Property 2 — cost basis and yield fee:** `check_property2_fullWithdrawalReleasesAllRemainingBasis`, `check_property2_partialWithdrawalReleasesOnlyItsShareOfBasis`, `check_property2_aLossNeverCreatesYieldFee`, and `check_property2_withdrawalWithoutCostBasisTreatsAllOutputAsYield` call the actual module release logic with symbolic `uint128` amounts. The full/partial/loss cases require `heldBefore > 0`; the separate no-basis check covers zero basis, including `heldBefore == 0`. `check_property2_yieldFeeNeverExceedsRoundedRate` exercises the actual fee module and proves the fee equals (and therefore is no greater than) the rounded-up formula for symbolic `uint8` yield and `uint8` rate (0–255 bps). A wider `uint32`-yield/`uint16`-rate version timed out; wider fee-bound inputs are not proven.
- **Property 5 — borrow fee monotonicity:** `check_property5_pendingBorrowFeeIsMonotonicInDebt` compares symbolic `uint8` debts (0–255) at a fixed timestamp and 100% plan rate. `check_property5_pendingBorrowFeeNeverFallsAfterOneMoreSecondAtFixedDebt` checks every symbolic elapsed duration 0–255 against the next second, at fixed debt `1e18` and the same rate. Both call the actual `_pendingFee` through a minimal harness. A check with symbolic time and debt together timed out; these bounded, single-axis proofs do not cover every debt/time combination.
- **Property 6 — UserOp signature:** `check_property6_erc1271OwnerCanApproveShortNonAdapterOperation` calls the actual `_validateUserOpSignature` through `validateSignature` for symbolic 3-byte call data and 19-byte paymaster data, using an ERC-1271 owner mock that always approves. Owner/operator/outsider ECDSA decision checks through the actual validator were attempted with fixed keys signing `MessageHashUtils.toEthSignedMessageHash(USER_OP_HASH)` and a symbolic selector/paymaster, but Halmos 0.3.3 rejected them even though direct recovery matched the owner. Those checks were removed; the ECDSA decision table is covered by `testFuzz_onlyOwnerOrSponsoredOperatorAdapterCallsPassSignatureValidation` with real signatures.
- **Property 11 — borrow swap result formula:** the three `check_property11_...` checks call the actual `checkSwapResult`. Sold amount, bought amount, held balance, and oracle quote are symbolic `uint256`; debt is symbolic `uint240` so the buffered multiplication fits `uint256`. Minimal oracle, token, and fee-module mocks supply the symbolic quote, held amount, and debt. The checks cover the base-asset swap price floor (ceil, 500 bps slippage) and the buffered debt ceiling (300 bps). `checkSwap` token-direction / reward-sale rules are not covered here.
- **Property 13 — decimal scaling and monotonicity:** the actual `PriceOracle.quote` is checked with equal $1 mock prices, 6-decimal and 18-decimal tokens. Six-to-eighteen scaling covers symbolic amounts 0–255; eighteen-to-six covers symbolic amounts through `2^40-1`, including nonzero whole-unit quotes. The adjacent-step check proves no decrease from each amount 0–254 to the next; by transitivity this covers the `uint8` domain. A two-independent-amount monotonicity check timed out, so monotonicity is only proven over that `uint8` domain by adjacent steps. Other decimal pairs, varying prices, overflow at realistic price ranges, stale-feed rejection, and sequencer rejection are not proven here.

**Property 3 (withdrawal splitting) is not proven.** An isolated check of the actual release logic, narrowed to `uint8` amounts and set up outside the symbolic test, still exceeded a 120-second wall-clock limit. It was removed from the final `check_` suite; no result is claimed.
