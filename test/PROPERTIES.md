# Contract properties

Each property is a promise the V3 contracts make to owners, operators or YieldSeeker, written as something an owner, power user or attacker could try to break. Three layers check them:

- **Fuzz / invariant (Foundry):** runs real workflows with random amounts, prices, times and callers. Invariant tests run random sequences of owner, operator and attacker actions and check the promise after every step.
- **Halmos:** symbolic execution; proves a small function for every input in a bounded range.
- **Certora:** proves a rule for every input and, for parametric rules, every wallet method.

## Running

| Command | What it runs | Time on an M-series Mac |
| --- | --- | ---: |
| `make test` | Unit, integration, fuzz (256 runs) and invariant (64 × 64 calls) tests; this is what CI runs | ~1 min |
| `make test-deep` | Fuzz at 20,000 runs and invariants at 1,000 × 200 calls | ~5 min |
| `make prove-halmos` | Halmos proofs, see `test/formal/halmos/README.md` | ~5 min |
| `make prove-certora` | Local Certora Prover, see `certora/README.md` for one-time setup | ~4 min |

Proofs and deep runs are local only; no hosted prover is used.

## Properties

| # | Promise | Fuzz / invariant | Proof |
| --- | --- | --- | --- |
| 1 | Every fee charged is either still owed or was paid; the collector receives exactly what was paid; a payment never exceeds the wallet's base asset | `invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows`, `testFuzz_paymentIsCappedAndOwedFallsByExactPayment` | Certora `yieldFeeChargedEqualsOwedPlusPaid`, `borrowFeeChargedEqualsOwedPlusPaid`, `*PaymentDoesNotExceedLimit`, `trackerPaymentDoesNotExceedWalletBalance`, `trackerRejectsModuleOverpayment` |
| 2 | Yield fees are charged only on gains: withdrawals release cost basis in proportion, losses pay no fee | `testFuzz_fullWithdrawalReleasesAllCostBasis`, `testFuzz_partialWithdrawalReleasesProportionalBasis`, `testFuzz_lossWithdrawalReleasesBasisWithoutFee`, `testFuzz_withdrawalFromPositionWithoutBasisIsAllYield`, `testFuzz_yieldFeeIsBoundedByRoundedYieldRate` | Halmos `check_property2_*` |
| 3 | Splitting a withdrawal or checkpointing often cannot avoid fees (at most 1 unit of rounding per extra step) | `testFuzz_twoPartialWithdrawalsCannotAvoidFees`, `testFuzz_manyBorrowCheckpointsCannotAvoidFees` | Not proven: Halmos timed out |
| 4 | A wallet's recorded debt per token equals the sum of its debt positions | `invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows` | Certora `borrowTokenDebtMatchesPositionSum` |
| 5 | Borrow fees never fall as time passes, an unusable price keeps the last good one, and debt above `uint128` reverts instead of wrapping | `testFuzz_borrowFeeAccrualIsMonotonicInTime`, `testFuzz_unusableBorrowPriceKeepsTheLastUsablePrice`, `testFuzz_debtAboveUint128RevertsInsteadOfWrapping` | Halmos `check_property5_*` (bounded) |
| 6 | Only the owner, or an operator sending a sponsored adapter call, passes UserOp signature validation | `testFuzz_onlyOwnerOrSponsoredOperatorAdapterCallsPassSignatureValidation` | Halmos `check_property6_erc1271OwnerCanApproveShortNonAdapterOperation` (ERC-1271 owner only) |
| 7 | An attacker cannot change a wallet's owner, blocklists or implementation, or move its funds | `testFuzz_attackerCannotCallAnyPrivilegedWalletFunction`, `invariant_attackerCannotPullOrReceiveWalletTokens` | Certora `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances` over 22 wallet methods |
| 8 | The owner can always withdraw, even if a fee module or the fee collector misbehaves | `testFuzz_ownerCanWithdrawEverythingWhenAFeeModuleIsHostile`, `testFuzz_ownerCanWithdrawEverythingWhenTheFeeCollectorRejectsPayment` | — |
| 9 | `withdrawableBalance` is the balance less fees owed, never more than the balance | `testFuzz_withdrawableBalanceIsBalanceLessFeesOwed` | — |
| 10 | Only registered, unblocked adapter/target pairs on an unpaused registry execute | `testFuzz_onlyRegisteredUnblockedUnpausedAdapterTargetPairsExecute`, `invariant_walletFundsStayWithOwnersOrRegisteredProtocolTargets` | — |
| 11 | Borrow swaps respect oracle slippage, keep held debt token ≤ debt + 3%, and never sell borrowed tokens; vault swaps only sell rewards into the base asset | `testFuzz_borrowSwapPolicyMatchesOracleAndDebtReferenceModel`, `testFuzz_vaultSwapPolicyOnlySellsAllowedRewardsIntoBase`, `testPowerUserSellsCollateralAndRepaysUntilTheBorrowIsClosed` | Halmos `check_property11_*` (result formula) |
| 12 | Swap adapters spend exactly the input, count the lower of measured and reported output, and enforce deadline and route | `testFuzz_eachDexCountsMinimumOfMeasuredAndReportedOutput`, `test_eachDexUsesExactInputAndPassesValidatedRouteAndDeadline`, `test_eachDexRejectsUnderSpendUnderDeliveryAndLateDelivery`, `test_eachDexRejectsExpiredSwapsAndRouteEndpointMismatchBeforeRouterCall` | — |
| 13 | Oracle quotes convert decimals correctly and reject stale feeds and a down or recovering sequencer | `testFuzz_quoteMatchesUnitConversionAndNeverOverflows`, `test_quoteRejectsStaleFeedAndSequencerDownOrInGracePeriod` | Halmos `check_property13_*` (6 and 18 decimals, bounded) |
| 14 | Only the admin changes the adapter registry; pause blocks execution lookups but not the read-only target list | `invariant_attackerWorkflowsNeverChangeRegistryState`, `invariant_targetLookupOnlyReturnsActiveMappingsAndRevertsWhilePaused`, `invariant_getAllTargetsMatchesActiveGhostSetWhilePausedOrRunning` | — |
| 15 | An owner's agents can move exact amounts between each other after paying fees; other owners, spoofed wallets, self and mid-execution receivers are rejected | `testFuzz_ownersAgentsCanMoveExactAmountsBetweenEachOther`, `testFuzz_transfersToOtherOwnersSpoofedWalletsOrSelfAreRejected`, `testFuzz_senderPaysFeesOwedBeforeMovingFundsToAnotherAgent`, `testFuzz_walletMidExecutionCannotReceiveAgentTransfers` | — |
| 16 | A wallet lands at its predicted address and an owner/index pair cannot be created twice | `testFuzz_walletLandsAtPredictedAddressAndCannotBeCreatedTwice` | — |

## Known limits

- **`syncFromFactory`** is permissionless by design (it copies the factory's admin-set operators and registry), so the Certora authorization rule excludes it.
- **Certora properties 4 and 7** compile with the legacy pipeline and optimisations off, so they check the source logic rather than the production `via_ir` bytecode.
- **Halmos bounds:** several proofs use `uint8` ranges because wider ranges timed out; each README lists its bounds.
