# Fees


## Action reporting and plans

Adapters report `DEPOSIT`, `WITHDRAW`, `SWAP`, `REWARD_SALE`, `CLAIM`, `DEBT_CHANGE` or `TRANSFER_OUT` to the wallet's `YieldSeekerFeeTracker`; the wallet reports `TRANSFER_OUT` before owner withdrawals. The tracker calls its modules in insertion order. Each module records the action and takes what it is owed from the base asset left by earlier modules. The adapter transfers the total to the collector once per report.

The tracker holds one module per fee type, ABI-encoded plans per fee type and wallet plan IDs. Only the timelock admin configures modules, plans, wallet factory and collector. Only the factory sets wallet plans at creation. Plans do not change; fee types without an explicit wallet plan use plan `0`. A new plan applies only to wallets assigned to it at creation, except a fee type's first plan `0` is used by wallets without a recorded choice.

A replacement module must use the same tracker and fee type and accept all existing plans. `isAccountedToken` and `feesOwedInBaseAsset` call each module with a gas limit; a failing module counts as false or zero in those views. A module that reverts during `reportAction` reverts the adapter action.

## Yield fee

`YieldSeekerYieldFeeModule` (`YIELD_FEE`) tracks cost basis per wallet and target. Deposits add the base asset actually spent. A withdrawal releases the same fraction of basis as the fraction of the position removed. Output above released basis is yield; a loss reduces basis for that target. Losses are not carried between targets.

Base-asset rewards and base asset received for a `REWARD_SALE` are yield. Other swaps, including base asset sold for a borrowed token, are not yield. Reward tokens, gifted shares and other positions with no recorded basis are charged as yield when they are withdrawn or sold for the base asset, except the two cases in [Known risks](security.md#known-risks-accepted): rewards paid in a borrowed token, and rewards the owner sells through a route of their own. Fees round up.

## Borrow fee

`YieldSeekerBorrowFeeModule` (`BORROW_FEE`) charges a yearly rate on each debt position's last reported debt, including interest. The key is the borrow adapter's `debtPosition(market)`: Aave V4 keys debt by spoke and debt reserve, so markets on the same reserve share it and are charged once, and other markets use `marketTarget(market)`. Look positions up with `debtPosition(market)`, not the market target. Borrow adapters report borrows, repayments, collateral withdrawals and `checkpoint(market)` calls. A checkpoint reads current debt and moves no funds.

Each period is charged on debt at the previous report. The module converts the fee from the borrowed token into the base asset using the lending market's own price, not `YieldSeekerPriceOracle`. It uses the last reported price if a report has no price. Both accrual and conversion round up. Payment comes from base-asset balance at that report or a later reported action or outflow. The module records `tokenDebt(wallet, token)` across markets and accounts for borrowed tokens so owners may withdraw them.

Checkpoint each market with open debt at least daily and after a liquidation, but not much more often: each report can round the fee up by up to one raw debt-token unit, valued in the base asset (see the rounding item in [Known risks](security.md#known-risks-accepted)). Debt changes outside the adapter are otherwise reflected only at the next report. See [Known risks (accepted)](security.md#known-risks-accepted).

## Withdrawals and transfers

For fee-aware ERC20 owner withdrawals and agent-to-agent transfers, the wallet reports `TRANSFER_OUT` before sending tokens. The fee modules settle from the base asset. A successful fixed-amount ERC20 withdrawal sends exactly the requested token amount. `withdrawableBalance(asset)` reports the base-asset balance net of fees owed, the full balance of another accounted token, or zero for an unaccounted token.

Owner ERC20 withdrawal settlement is gas-limited and failure-tolerant. A module or collector failure during settlement does not block an owner exit; the wallet leaves fees owed and emits `FeeSettlementFailed`. Withdrawing a token other than the base asset, such as a borrowed token, first checks that the tracker accounts for it, and a reverting module makes that check fail, so those exits wait until the module is fixed. Adapter actions and agent transfers fail if a module or collector reverts. Native ETH withdrawals are owner-only and are not fee-settled.


## Changing fee logic

Fee state lives in modules. Replacing a yield module without importing state loses open-position basis and can charge the full withdrawal as yield. Replacing a borrow module without importing state loses debt positions, unpaid fees, borrowed-token accounting and `tokenDebt`; owners may then be unable to withdraw borrowed tokens, and the borrow swap policy will not recognize them. A new tracker also needs existing wallet plans imported or wallets use plan `0`.

- A new fee type needs an `IYieldSeekerFeeModule` implementation, a `setFeeModule` call and plans created with `createPlan`. Existing adapters need no change unless they must report new actions.
- A new action needs a new ID and struct in `FeeActions`, reporting from the adapter and handling in any module that charges for it. Do not change existing action structs.
- Plans are immutable. A new plan can be assigned only when creating a wallet. Moving an existing wallet to a different plan requires a new wallet. A replacement module can accept old plans and add new plan formats.
- A replacement module can import state lazily from the previous module. On first use, import the wallet's cost basis, debt positions, fees owed and, for borrow fees, `isBorrowedToken` and `tokenDebt`. Until import, views such as `isAccountedToken` and `feesOwedInBaseAsset` need to fall back to the old module. A replacement tracker must also read old wallet plans until they are imported and use modules built for that tracker. Adding a new fee type avoids replacing existing module state.
- Never reinstate a module that was replaced. It resumes from the state it had when it was replaced and charges the time since then again. Roll back by deploying a fresh module that imports state.
- Charging a reward paid in a borrowed token (see [Known risks](security.md#known-risks-accepted)) needs a fee module that values those claims. Until one exists, don't register other reward sources that pay borrowed tokens in a borrow registry.

