methods {
    // The harness is its own fee tracker; route the module's plan lookup to it instead of an arbitrary result.
    function _.walletPlan(address, bytes32) external => DISPATCHER(true);
}

ghost mapping(address => mathint) feeCharged;
ghost mapping(address => mathint) feePaid;

hook event BorrowFeeCharged(address indexed wallet, address indexed position, address indexed debtToken, uint256 fee, uint256 feeInBaseAsset) {
    feeCharged[wallet] = feeCharged[wallet] + feeInBaseAsset;
}

hook event FeePaid(address indexed wallet, uint256 amount) {
    feePaid[wallet] = feePaid[wallet] + amount;
}

// Property 1: a borrow fee charge is either still owed or was returned as payment by this action.
rule borrowFeeChargedEqualsOwedPlusPaid(env e, bytes32 action, bytes data, uint256 maxPayment) {
    address wallet = e.msg.sender;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    feeCharged[wallet] = 0;
    feePaid[wallet] = 0;

    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);

    assert payment == feePaid[wallet];
    assert feeCharged[wallet] + owedBefore == currentContract.feesOwed(e, wallet) + feePaid[wallet];
    satisfy payment > 0 && feeCharged[wallet] > 0 && feePaid[wallet] > 0,
        "a debt checkpoint can charge and pay a non-zero borrow fee";
}

// Property 1: a borrow fee module never returns more than the tracker made available for payment.
rule borrowFeePaymentDoesNotExceedLimit(env e, bytes32 action, bytes data, uint256 maxPayment) {
    address wallet = e.msg.sender;
    feeCharged[wallet] = 0;
    feePaid[wallet] = 0;
    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);
    assert payment <= maxPayment;
    satisfy payment > 0 && feeCharged[wallet] > 0 && feePaid[wallet] > 0,
        "a non-zero borrow fee can be paid within a non-zero allowance";
}

// Property 5: a checkpoint a year after the last report charges exactly the plan rate on the last reported debt, rounded up.
// Rate, time and price are fixed so the solver only reasons about one symbolic factor; the fuzz tests and Halmos vary them.
rule checkpointChargesPlanRateOnLastDebtForAYear(env e, address market, address debtToken, uint256 debtBefore) {
    address wallet = currentContract;
    uint128 lastDebt;
    uint64 lastAccrual;
    uint192 lastPrice;
    lastDebt, lastAccrual, lastPrice = currentContract.debtPositions(e, wallet, market);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.planRateBps(e) == 100;
    require e.block.timestamp == lastAccrual + 365 * 86400;

    currentContract.reportCheckpoint(e, market, debtToken, debtBefore, 10^36);

    assert currentContract.feesOwed(e, wallet) - owedBefore == (lastDebt * 100 + 9999) / 10000;
    satisfy lastDebt > 0;
}

// Property 5: the fee is valued in the base asset at the price reported with the checkpoint, rounded up.
rule checkpointValuesTheFeeAtTheReportedPrice(env e, address market, address debtToken, uint256 debtBefore, uint256 price) {
    address wallet = currentContract;
    uint128 lastDebt;
    uint64 lastAccrual;
    uint192 lastPrice;
    lastDebt, lastAccrual, lastPrice = currentContract.debtPositions(e, wallet, market);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.planRateBps(e) == 10000;
    require lastDebt == 10^18;
    require e.block.timestamp == lastAccrual + 365 * 86400;
    require price > 0 && price <= max_uint192;

    currentContract.reportCheckpoint(e, market, debtToken, debtBefore, price);

    assert currentContract.feesOwed(e, wallet) - owedBefore == (10^18 * price + 10^36 - 1) / 10^36;
    satisfy price > 10^18;
}

// Property 4: fees owed, debt positions, token debt and borrowed-token flags change only when the fee tracker reports an action.
rule borrowFeeStateChangesOnlyThroughTrackerActions(method f, address wallet, address position, address token)
filtered {
    f -> !f.isView &&
        f.selector != sig:reportAction(bytes32, bytes, uint256).selector &&
        f.selector != sig:reachDebtChange().selector &&
        f.selector != sig:reportCheckpoint(address, address, uint256, uint256).selector &&
        f.selector != sig:reportNonDebtAction(bytes32, bytes).selector &&
        f.selector != sig:setPlanRate(uint256).selector
}
{
    env e;
    calldataarg args;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    uint128 lastDebtBefore;
    uint64 lastAccrualBefore;
    uint192 lastPriceBefore;
    lastDebtBefore, lastAccrualBefore, lastPriceBefore = currentContract.debtPositions(e, wallet, position);
    uint256 tokenDebtBefore = currentContract.tokenDebt(e, wallet, token);
    bool borrowedBefore = currentContract.isBorrowedToken(e, wallet, token);

    f(e, args);

    uint128 lastDebtAfter;
    uint64 lastAccrualAfter;
    uint192 lastPriceAfter;
    lastDebtAfter, lastAccrualAfter, lastPriceAfter = currentContract.debtPositions(e, wallet, position);
    bool changed = currentContract.feesOwed(e, wallet) != owedBefore || lastDebtAfter != lastDebtBefore || lastAccrualAfter != lastAccrualBefore ||
        lastPriceAfter != lastPriceBefore || currentContract.tokenDebt(e, wallet, token) != tokenDebtBefore || currentContract.isBorrowedToken(e, wallet, token) != borrowedBefore;
    assert changed => f.selector == sig:onAction(address, bytes32, bytes, uint256).selector && e.msg.sender == currentContract.FEE_TRACKER(e);
}

// Property 4: actions other than debt changes leave debt positions, token debt and fees owed alone.
rule nonDebtActionsLeaveDebtAndFeesAlone(env e, bytes32 action, bytes data, address position, address token) {
    address wallet = currentContract;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    uint128 lastDebtBefore;
    uint64 lastAccrualBefore;
    uint192 lastPriceBefore;
    lastDebtBefore, lastAccrualBefore, lastPriceBefore = currentContract.debtPositions(e, wallet, position);
    uint256 tokenDebtBefore = currentContract.tokenDebt(e, wallet, token);

    currentContract.reportNonDebtAction(e, action, data);

    uint128 lastDebtAfter;
    uint64 lastAccrualAfter;
    uint192 lastPriceAfter;
    lastDebtAfter, lastAccrualAfter, lastPriceAfter = currentContract.debtPositions(e, wallet, position);
    assert currentContract.feesOwed(e, wallet) == owedBefore;
    assert lastDebtAfter == lastDebtBefore && lastAccrualAfter == lastAccrualBefore && lastPriceAfter == lastPriceBefore;
    assert currentContract.tokenDebt(e, wallet, token) == tokenDebtBefore;
}

// Property 5: a usable price is stored with the checkpoint; a zero or oversized price keeps the last usable one.
rule checkpointKeepsTheLastUsablePrice(env e, address market, address debtToken, uint256 debtBefore, uint256 price) {
    address wallet = currentContract;
    uint128 lastDebt;
    uint64 lastAccrual;
    uint192 lastPriceBefore;
    lastDebt, lastAccrual, lastPriceBefore = currentContract.debtPositions(e, wallet, market);

    currentContract.reportCheckpoint(e, market, debtToken, debtBefore, price);

    uint128 lastDebtAfter;
    uint64 lastAccrualAfter;
    uint192 lastPriceAfter;
    lastDebtAfter, lastAccrualAfter, lastPriceAfter = currentContract.debtPositions(e, wallet, market);
    assert price > 0 && price <= max_uint192 => lastPriceAfter == price;
    assert price == 0 || price > max_uint192 => lastPriceAfter == lastPriceBefore;
    satisfy price == 0 && lastPriceBefore > 0;
}

