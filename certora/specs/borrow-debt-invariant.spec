methods {
    function Math.mulDiv(uint256, uint256, uint256, Math.Rounding) internal returns (uint256) => NONDET;
    function _.walletPlan(address, bytes32) external => NONDET;
}

ghost mapping(address => mapping(address => mathint)) debtSumByToken {
    init_state axiom forall address wallet. forall address token.
        debtSumByToken[wallet][token] == 0;
}

hook Sstore currentContract.debtPositions[KEY address wallet][KEY address position].lastDebt uint128 newDebt (uint128 oldDebt) {
    debtSumByToken[wallet][currentContract.debtTokenForPosition[wallet][position]] =
        debtSumByToken[wallet][currentContract.debtTokenForPosition[wallet][position]] + newDebt - oldDebt;
}

// Property 4: the tracker callback conserves token debt; fee-plan data is nondeterministic, and the harness fixes one debt token per market.
invariant borrowTokenDebtMatchesPositionSum(address wallet, address token)
    currentContract.tokenDebt[wallet][token] == debtSumByToken[wallet][token]
{
    preserved reportAction(bytes32 action, bytes data, uint256 maxPayment) with (env e) {
    }
    preserved onAction(address walletArg, bytes32 actionArg, bytes dataArg, uint256 maxPaymentArg) with (env e) {
        require e.msg.sender == currentContract.FEE_TRACKER(e);
        require currentContract.hasConsistentDebtToken(e, walletArg, actionArg, dataArg);
    }
}
