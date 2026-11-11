ghost mapping(address => mapping(address => mathint)) debtSumByToken {
    init_state axiom forall address wallet. forall address token.
        debtSumByToken[wallet][token] == 0;
}

hook Sstore currentContract.debtPositions[KEY address wallet][KEY address position].lastDebt uint128 newDebt (uint128 oldDebt) {
    debtSumByToken[wallet][currentContract.debtTokenForPosition[wallet][position]] =
        debtSumByToken[wallet][currentContract.debtTokenForPosition[wallet][position]] + newDebt - oldDebt;
}

// The tracker callback conserves token debt across positions, assuming each market keeps one debt token.
invariant borrowTokenDebtMatchesPositionSum(address wallet, address token)
    currentContract.tokenDebt[wallet][token] == debtSumByToken[wallet][token]
{
    preserved reportAction(bytes32 action, bytes data, uint256 maxPayment) with (env e) {
    }
    preserved onAction(address walletArg, bytes32 actionArg, bytes dataArg, uint256 maxPaymentArg) with (env e) {
        require e.msg.sender != currentContract;
    }
}
