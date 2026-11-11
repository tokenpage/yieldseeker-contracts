ghost mapping(address => mathint) feeCharged;
ghost mapping(address => mathint) feePaid;

hook event BorrowFeeCharged(address indexed wallet, address indexed position, address indexed debtToken, uint256 fee, uint256 feeInBaseAsset) {
    feeCharged[wallet] = feeCharged[wallet] + feeInBaseAsset;
}

hook event FeePaid(address indexed wallet, uint256 amount) {
    feePaid[wallet] = feePaid[wallet] + amount;
}

// A borrow fee charge is either still owed or was returned as payment by this action.
rule borrowFeeChargedEqualsOwedPlusPaid(env e, bytes32 action, bytes data, uint256 maxPayment) {
    address wallet = e.msg.sender;
    uint256 owedBefore = currentContract.feesOwed(e, wallet);
    feeCharged[wallet] = 0;
    feePaid[wallet] = 0;

    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);

    assert payment == feePaid[wallet];
    assert feeCharged[wallet] + owedBefore == currentContract.feesOwed(e, wallet) + feePaid[wallet];
}

// A borrow fee module never returns more than the tracker made available for payment.
rule borrowFeePaymentDoesNotExceedLimit(env e, bytes32 action, bytes data, uint256 maxPayment) {
    uint256 payment = currentContract.reportAction(e, action, data, maxPayment);
    assert payment <= maxPayment;
}
