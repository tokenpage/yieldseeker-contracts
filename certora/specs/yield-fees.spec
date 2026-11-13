methods {
    // The harness is its own fee tracker; route the module's plan lookup to it instead of an arbitrary result.
    function _.walletPlan(address, bytes32) external => DISPATCHER(true);
}

ghost mapping(address => mathint) feeCharged;
ghost mapping(address => mathint) feePaid;

hook event YieldRecorded(address indexed wallet, uint256 yieldAmount, uint256 fee) {
    feeCharged[wallet] = feeCharged[wallet] + fee;
}

hook event FeePaid(address indexed wallet, uint256 amount) {
    feePaid[wallet] = feePaid[wallet] + amount;
}

// Property 1: a yield fee charge is either still owed or was returned as payment by this action.
rule yieldFeeChargedEqualsOwedPlusPaid(env e, bytes32 action, bytes data, uint256 maxPayment) {
    address wallet = e.msg.sender;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    feeCharged[wallet] = 0;
    feePaid[wallet] = 0;

    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);

    assert payment == feePaid[wallet];
    assert feeCharged[wallet] + owedBefore == currentContract.feesOwed(e, wallet) + feePaid[wallet];
    satisfy payment > 0 && feeCharged[wallet] > 0 && feePaid[wallet] > 0,
        "a withdrawal can charge and pay a non-zero yield fee";
}

// Property 1: a yield fee module never returns more than the tracker made available for payment.
rule yieldFeePaymentDoesNotExceedLimit(env e, bytes32 action, bytes data, uint256 maxPayment) {
    address wallet = e.msg.sender;
    feeCharged[wallet] = 0;
    feePaid[wallet] = 0;
    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);
    assert payment <= maxPayment;
    satisfy payment > 0 && feeCharged[wallet] > 0 && feePaid[wallet] > 0,
        "a non-zero yield fee can be paid within a non-zero allowance";
}

// Reachability witness: a withdrawal with no prior position basis can produce a non-zero fee and payment.
rule yieldFeeChargeAndPaymentReachable(env e) {
    feeCharged[currentContract] = 0;
    feePaid[currentContract] = 0;
    uint256 payment = currentContract.reachFeeChargeAndPayment(e);
    satisfy payment > 0 && feeCharged[currentContract] > 0 && feePaid[currentContract] > 0;
}

// Property 2: a full withdrawal clears the position's cost basis and charges exactly the plan rate of the gain, rounded up.
// The rate is fixed at 20% so the solver only reasons about one symbolic factor; the fuzz tests and Halmos vary the rate.
rule fullWithdrawalChargesPlanRateOfGainAndClearsBasis(env e, address target, uint256 heldBefore, uint256 assetsOut) {
    address wallet = currentContract;
    uint256 basis = currentContract.costBasis(e, wallet, target);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.planRateBps(e) == 2000;
    require heldBefore > 0;
    require assetsOut <= max_uint128 && basis <= max_uint128;

    currentContract.reportFullWithdrawal(e, target, heldBefore, assetsOut);

    mathint gain = assetsOut > basis ? assetsOut - basis : 0;
    assert currentContract.costBasis(e, wallet, target) == 0;
    assert currentContract.feesOwed(e, wallet) - owedBefore == (gain * 2000 + 9999) / 10000;
    satisfy gain > 0;
}

// Property 1: fees owed and cost basis change only when the fee tracker reports an action.
rule yieldFeeStateChangesOnlyThroughTrackerActions(method f, address wallet, address target)
filtered {
    f -> !f.isView &&
        f.selector != sig:reportAction(bytes32, bytes, uint256).selector &&
        f.selector != sig:reachFeeChargeAndPayment().selector &&
        f.selector != sig:reportFullWithdrawal(address, uint256, uint256).selector &&
        f.selector != sig:setPlanRate(uint256).selector
}
{
    env e;
    calldataarg args;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    uint256 basisBefore = currentContract.costBasis(e, wallet, target);

    f(e, args);

    bool changed = currentContract.feesOwed(e, wallet) != owedBefore || currentContract.costBasis(e, wallet, target) != basisBefore;
    assert changed => f.selector == sig:onAction(address, bytes32, bytes, uint256).selector && e.msg.sender == currentContract.FEE_TRACKER(e);
}
