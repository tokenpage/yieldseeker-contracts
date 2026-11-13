# Contract properties

Each property is a promise the V3 contracts make to owners, operators or YieldSeeker, written as something an owner, power user or attacker could try to break. Four layers check them:

- **Fuzz and invariant tests (Foundry):** real workflows with random amounts, prices, times and callers. Invariant suites run random sequences of owner, operator and attacker actions and check every promise after each step.
- **Halmos:** proves a small function for every input in a bounded range.
- **Certora:** proves a rule for every input and, for parametric rules, every wallet method.
- **Mutation testing (Gambit):** plants small bugs in `src/` and checks that some test fails.

## Running

| Command | What it runs | Time on a 12-core M-series Mac |
| --- | --- | ---: |
| `make test` | Unit, integration, fuzz (256 runs) and invariant (64 × 64 calls) tests; this is what CI runs | ~3 min |
| `make test-deep` | Fuzz at 20,000 runs and invariants at 1,000 × 200 calls | ~70 min |
| `make prove-halmos` | Halmos proofs, see `test/formal/halmos/README.md` | ~6 min |
| `make prove-certora` | Local Certora Prover, see `certora/README.md` for one-time setup | ~5 min |
| `make test-mutation` | Every mutant of the core contracts against `make test`; needs Gambit (`cargo install --locked --git https://github.com/Certora/gambit.git`) and solc 0.8.38 (`solc-select`). Results go to `$RESULTS_DIR` (default `/tmp/yieldseeker-mutation`) and the run resumes if stopped | ~6 h |
| `make test-fork` | Fork tests against the real protocols on Base | ~1 min |

Everything runs locally; no hosted prover is used.

## Properties

| # | Promise | Fuzz / invariant | Proof |
| --- | --- | --- | --- |
| 1 | Every fee charged is either still owed or was paid; the collector receives exactly what was paid; a payment never exceeds the wallet's base asset; a replaced fee module stops charging | `invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows`, `testFuzz_paymentIsCappedAndOwedFallsByExactPayment`, `test_feeConfigurationPlanAndTrackerRejections`, `test_feesAndFeeEventsOnlyAppearForRealYieldDebtAndPayments` | Certora `yieldFeeChargedEqualsOwedPlusPaid`, `borrowFeeChargedEqualsOwedPlusPaid`, `*PaymentDoesNotExceedLimit`, `*StateChangesOnlyThroughTrackerActions`, `trackerPaymentDoesNotExceedWalletBalance`, `trackerRejectsModuleOverpayment` |
| 2 | Yield fees are charged only on gains: withdrawals release cost basis in proportion, losses pay no fee, base-asset claims and reward sales are yield, other actions are not | `testFuzz_fullWithdrawalReleasesAllCostBasis`, `testFuzz_partialWithdrawalReleasesProportionalBasis`, `testFuzz_lossWithdrawalReleasesBasisWithoutFee`, `testFuzz_withdrawalFromPositionWithoutBasisIsAllYield`, `testFuzz_yieldFeeIsBoundedByRoundedYieldRate` | Halmos `check_property2_*`; Certora `fullWithdrawalChargesPlanRateOfGainAndClearsBasis`, `halfWithdrawalReleasesHalfTheBasis`, `withdrawalFromAnEmptyPositionIsAllYield`, `depositAddsItsAssetsToCostBasisAndChargesNothing`, `baseAssetClaimsAndRewardSalesAreYield`, `otherActionsAreNotYield` (20% rate) |
| 3 | Splitting a withdrawal or checkpointing often cannot avoid fees (at most 1 unit of rounding per extra step) | `testFuzz_twoPartialWithdrawalsCannotAvoidFees`, `testFuzz_manyBorrowCheckpointsCannotAvoidFees` | Certora `splittingAWithdrawalCannotAvoidYieldFees` (two halves never pay less than one withdrawal, 20% rate); borrow checkpoints not proven (the solver times out) |
| 4 | A wallet's recorded debt per token equals the sum of its debt positions | `invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows`, `invariant_powerUserPositionsAndFeeLedgersMatchWalletActivity` | Certora `borrowTokenDebtMatchesPositionSum`, `borrowFeeStateChangesOnlyThroughTrackerActions` |
| 5 | Borrow fees are the plan rate on the last debt for the time elapsed, valued at the reported price; they never fall as time passes, an unusable price keeps the last good one, and debt above `uint128` reverts instead of wrapping | `testFuzz_borrowFeeAccrualIsMonotonicInTime`, `testFuzz_unusableBorrowPriceKeepsTheLastUsablePrice`, `testFuzz_debtAboveUint128RevertsInsteadOfWrapping` | Halmos `check_property5_*` (bounded); Certora `checkpointChargesPlanRateOnLastDebtForAYear`, `checkpointValuesTheFeeAtTheReportedPrice`, `checkpointKeepsTheLastUsablePrice`, `debtChangeRecordsTheNewDebtTimeAndBorrowedToken` |
| 6 | Only the owner, or an operator sending a sponsored adapter call, passes UserOp signature validation | `testFuzz_onlyOwnerOrSponsoredOperatorAdapterCallsPassSignatureValidation` | Certora `adapterCallSignaturesValidateOnlyForTheOwnerOrASponsoredOperator`, `otherCallSignaturesValidateOnlyForTheOwner`, `shortCallDataOrPaymasterValidatesOnlyForTheOwner`; Halmos `check_property6_erc1271OwnerCanApproveShortNonAdapterOperation` (ERC-1271 owner) |
| 7 | An attacker cannot change a wallet's owner, blocklists or implementation, or move its funds; for any caller the owner never changes, the registry and operators change only through the factory sync, blocklists only by the owner, and tracker settings only by its admin | `testFuzz_attackerCannotCallAnyPrivilegedWalletFunction`, `invariant_attackerCannotPullOrReceiveWalletTokens` | Certora `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances`, `walletOwnerNeverChanges`, `walletRegistryAndOperatorsChangeOnlyThroughSync`, `walletBlocklistsChangeOnlyByOwner`, `trackerConfigurationChangesOnlyThroughAuthorisedSetters` |
| 8 | The owner can always withdraw, even if a fee module or the fee collector misbehaves | `testFuzz_ownerCanWithdrawEverythingWhenAFeeModuleIsHostile`, `testFuzz_ownerCanWithdrawEverythingWhenTheFeeCollectorRejectsPayment` | Certora `ownerWithdrawalMovesExactlyTheAmount` (no fees due), `withdrawalAtALossNeverRevertsAndChargesNothing` |
| 9 | `withdrawableBalance` is the balance less fees owed, never more than the balance | `testFuzz_withdrawableBalanceIsBalanceLessFeesOwed`, `invariant_powerUserValueAndWithdrawableBalanceStayWithinAllowedCosts` | Certora `withdrawableBalanceIsTheBaseAssetLessFeesOwed` |
| 10 | Only registered, unblocked adapter/target pairs on an unpaused registry execute; adapters reject unknown operations and failed protocol calls | `testFuzz_onlyRegisteredUnblockedUnpausedAdapterTargetPairsExecute`, `invariant_walletFundsStayWithOwnersOrRegisteredProtocolTargets`, `test_ownerAndOperatorRejectInvalidWalletAndAdapterInputs`, `test_adaptersRejectZeroAddressesUnknownOperationsAndFailedProtocolCalls` | Certora `adaptersRunOnlyWhenRegisteredUnblockedAndCalledByAnExecutor`, `adapterBatchesNeedMatchingArraysAndRegisteredUnblockedAdapters` |
| 11 | Borrow swaps respect oracle slippage, keep held debt token ≤ debt + 3%, and never sell borrowed tokens; vault swaps only sell rewards into the base asset | `testFuzz_borrowSwapPolicyMatchesOracleAndDebtReferenceModel`, `testFuzz_vaultSwapPolicyOnlySellsAllowedRewardsIntoBase`, `testPowerUserSellsCollateralAndRepaysUntilTheBorrowIsClosed` | Halmos `check_property11_*` (result formula) |
| 12 | Swap adapters spend exactly the input (sweeping router-held ETH first), count the lower of measured and reported output, enforce deadline and route, and let reward sales run while fees are owed | `testFuzz_eachDexCountsMinimumOfMeasuredAndReportedOutput`, `test_eachDexUsesExactInputAndPassesValidatedRouteAndDeadline`, `test_eachDexRejectsUnderSpendUnderDeliveryAndLateDelivery`, `test_eachDexRejectsExpiredSwapsAndRouteEndpointMismatchBeforeRouterCall`, `test_rewardSalesStillWorkWhileBorrowFeesStayOwed` | — |
| 13 | Oracle quotes convert decimals correctly and reject stale feeds and a down or recovering sequencer | `testFuzz_quoteMatchesUnitConversionAndNeverOverflows`, `test_quoteRejectsStaleFeedAndSequencerDownOrInGracePeriod` | Halmos `check_property13_*` (6 and 18 decimals, bounded) |
| 14 | Only the admin changes the adapter registry; pause blocks execution lookups but not the read-only target list | `invariant_attackerWorkflowsNeverChangeRegistryState`, `invariant_targetLookupOnlyReturnsActiveMappingsAndRevertsWhilePaused`, `invariant_getAllTargetsMatchesActiveGhostSetWhilePausedOrRunning` | — |
| 15 | An owner's agents can move exact amounts between each other after paying fees; other owners, wallets built outside the factory, self and mid-execution receivers are rejected | `testFuzz_ownersAgentsCanMoveExactAmountsBetweenEachOther`, `testFuzz_transfersToOtherOwnersSpoofedWalletsOrSelfAreRejected`, `testFuzz_senderPaysFeesOwedBeforeMovingFundsToAnotherAgent`, `testFuzz_walletMidExecutionCannotReceiveAgentTransfers`, `test_walletsBuiltOutsideTheFactoryCannotInitializeBadlyOrActAsTheOwnersAgent` | — |
| 16 | A wallet lands at its predicted address, cannot be created twice, and neither the factory nor a directly deployed proxy accepts a bad owner, base asset or configuration | `testFuzz_walletLandsAtPredictedAddressAndCannotBeCreatedTwice`, `test_factoryRejectsInvalidConfigurationAndWalletCreationInputs`, `test_walletsBuiltOutsideTheFactoryCannotInitializeBadlyOrActAsTheOwnersAgent` | — |
| 17 | A stolen operator key cannot take owner value beyond the README's accepted losses (reward dumps, the 1% swap floor, the 3% debt buffer, Morpho's ≈4.4% liquidation bonus, vault fees, interest and borrow fees), cannot touch other owners, wallet ETH or EntryPoint deposits, and every forbidden call fails; owners can still exit everything | `invariant_compromisedOperatorCannotTakeOwnerValueAndOwnersCanExit`, `testFuzz_compromisedOperatorWorstCaseStaysWithinReadmeBounds` | — |
| 18 | Honest owners using every adapter for months keep positions, cost basis, debt and fees in agreement with an independent model, lose value only to fees, interest, market moves and allowed slippage, and can always close out completely | `invariant_powerUserPositionsAndFeeLedgersMatchWalletActivity`, `invariant_powerUserValueAndWithdrawableBalanceStayWithinAllowedCosts`, `invariant_powerUserCanAlwaysCloseOutEveryPosition`, `testFuzz_vaultOwnerLifecycleFromFirstDepositToFullExit`, `testFuzz_borrowOwnerLifecycleFromFirstDepositToFullExit`, `test_powerUserRunsEveryAdapterThenClosesOutCleanly` | — |

`invariant_feeAccountingHoldsAcrossUserAndOperatorWorkflows` compares the modules' fee events with their stored balances and the collector's real balance; the expected fee amounts themselves are computed independently in the fee fuzz tests and the power-user suite.

## Mutation testing

The last full run generated 792 mutants of 20 core contracts (fees, swap policies, oracle, wallet, factory, registry, transfer, swap, lending and vault adapters). 9 did not compile. Of the other 783, 768 make at least one test fail (98.1%). The 15 that survive cannot change behaviour that matters:

| Mutants | Why they survive |
| --- | --- |
| `BorrowFeeModule` 208, 278; `YieldFeeModule` 148 | Remove an early `return 0` where the formula already gives 0 |
| `AgentWalletV3` 425; `AWKAgentWalletV3` 489 | Remove a zero-address check; the next `code.length == 0` check rejects zero with the same error |
| `AgentWalletV3` 454 | Sends a zero-amount fee transfer, a no-op for standard ERC-20s |
| `AWKAgentWalletV3` 463 | Removes a reentrancy check from `onlyExecutors`; both functions using it are also `nonReentrant` |
| `AWKAgentWalletV3` 509 | Removes a call to `_validateNonce`, an empty hook; the EntryPoint checks nonces |
| `AWKAgentWalletFactory` 600 | Removes the zero-owner check; the wallet's initializer rejects it with the same error |
| `AgentWalletV3` 427; `AWKAgentWalletV3` 491 | Remove a no-code check on the tracker or registry; the factory setters only accept contracts |
| `AWKAgentWalletV3` 560 | Removes a zero-asset check the YieldSeeker wallet never reaches (`InvalidAsset` comes first) |
| `AWKAgentWalletV3` 555, 556 | Change generic withdraw hooks that the YieldSeeker wallet overrides |
| `FeeTracker` 92 | Moves the module gas margin by 10,000 gas; pinning it would pin exact gas costs |

## Known limits

- **`syncFromFactory`** is permissionless by design (it copies the factory's admin-set operators and registry), so the Certora authorization rule excludes it.
- **Certora assumptions:** the exact-fee rules fix all but one factor (rate, time, debt or price) so the solver can finish; the tracker and wallet state-change configs consider at most two items per loop; `wallet-state-changes.conf` assumes external calls do not re-enter the wallet. The harness is not a proxy, so upgrade authorization is covered by Foundry tests on real proxies. `certora/README.md` lists every assumption.
- **Halmos bounds:** several proofs use `uint8` ranges because wider ranges timed out; each README lists its bounds.
- **Mocks:** the invariant suites use the repository's protocol mocks plus a Morpho-style market with interest and liquidation; `make test-fork` runs the adapters against the real protocols on Base.
