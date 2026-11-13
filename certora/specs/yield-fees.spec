methods {
    // The harness is its own fee tracker; route the module's plan lookup to it instead of an arbitrary result.
    function _.walletPlan(address, bytes32) external => DISPATCHER(true);
    function _.baseAsset() external => DISPATCHER(true);
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
        f.selector != sig:reportWithdrawal(address, uint256, uint256, uint256).selector &&
        f.selector != sig:reportDeposit(address, uint256).selector &&
        f.selector != sig:reportClaim(address, uint256).selector &&
        f.selector != sig:reportRewardSale(address, uint256, address, uint256).selector &&
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

function feeAtTwentyPercent(mathint yieldAmount) returns mathint {
    return (yieldAmount * 2000 + 9999) / 10000;
}

// Property 2: a deposit adds exactly its assets to the position's cost basis and charges nothing.
rule depositAddsItsAssetsToCostBasisAndChargesNothing(env e, address target, uint256 assetsIn) {
    address wallet = currentContract;
    uint256 basis = currentContract.costBasis(e, wallet, target);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);

    currentContract.reportDeposit(e, target, assetsIn);

    assert currentContract.costBasis(e, wallet, target) == basis + assetsIn;
    assert currentContract.feesOwed(e, wallet) == owedBefore;
}

// Property 2: base asset from a claim or a reward sale is all yield; other tokens are not yield.
rule baseAssetClaimsAndRewardSalesAreYield(env e, address claimed, uint256 claimAmount, address sold, uint256 soldAmount, address bought, uint256 boughtAmount) {
    address wallet = currentContract;
    address baseAsset = currentContract.baseAsset(e);
    require currentContract.planRateBps(e) == 2000;
    require claimAmount <= max_uint128 && boughtAmount <= max_uint128;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);

    currentContract.reportClaim(e, claimed, claimAmount);
    uint256 owedAfterClaim = currentContract.feesOwed(e, wallet);
    currentContract.reportRewardSale(e, sold, soldAmount, bought, boughtAmount);

    assert owedAfterClaim - owedBefore == (claimed == baseAsset ? feeAtTwentyPercent(claimAmount) : 0);
    assert currentContract.feesOwed(e, wallet) - owedAfterClaim == (bought == baseAsset ? feeAtTwentyPercent(boughtAmount) : 0);
    satisfy claimed == baseAsset && claimAmount > 0;
}

// Property 2: withdrawing half a position releases half its basis (rounded down) and charges the plan rate on the rest of the output.
rule halfWithdrawalReleasesHalfTheBasis(env e, address target, uint256 assetsOut) {
    address wallet = currentContract;
    uint256 basis = currentContract.costBasis(e, wallet, target);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.planRateBps(e) == 2000;
    require assetsOut <= max_uint128 && basis <= max_uint128;

    currentContract.reportWithdrawal(e, target, 1, 2, assetsOut);

    mathint released = basis / 2;
    mathint gain = assetsOut > released ? assetsOut - released : 0;
    assert currentContract.costBasis(e, wallet, target) == basis - released;
    assert currentContract.feesOwed(e, wallet) - owedBefore == feeAtTwentyPercent(gain);
    satisfy released > 0 && gain > 0;
}

// Property 2: output from a position the wallet held nothing in is all yield and leaves the basis alone.
rule withdrawalFromAnEmptyPositionIsAllYield(env e, address target, uint256 spent, uint256 assetsOut) {
    address wallet = currentContract;
    uint256 basis = currentContract.costBasis(e, wallet, target);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.planRateBps(e) == 2000;
    require assetsOut <= max_uint128;

    currentContract.reportWithdrawal(e, target, spent, 0, assetsOut);

    assert currentContract.costBasis(e, wallet, target) == basis;
    assert currentContract.feesOwed(e, wallet) - owedBefore == feeAtTwentyPercent(assetsOut);
}

// Property 8: a withdrawal at a loss never reverts and charges nothing.
rule withdrawalAtALossNeverRevertsAndChargesNothing(env e, address target, uint256 heldBefore, uint256 assetsOut) {
    address wallet = currentContract;
    uint256 basis = currentContract.costBasis(e, wallet, target);
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    require currentContract.FEE_TRACKER(e) == currentContract;
    require currentContract.planRateBps(e) <= 10000;
    require e.msg.value == 0;
    require heldBefore > 0 && assetsOut <= basis;

    currentContract.reportFullWithdrawal@withrevert(e, target, heldBefore, assetsOut);

    assert !lastReverted;
    assert currentContract.feesOwed(e, wallet) == owedBefore;
}

// Plans: a yield plan is valid exactly when its rate is at most the module's maximum.
rule plansAreValidExactlyUpToTheMaximumRate(env e, uint256 rateBps) {
    assert currentContract.isValidRate(e, rateBps) == (rateBps <= currentContract.MAX_FEE_RATE_BPS(e));
}
