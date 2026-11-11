methods {
    unresolved external in _.onAction(address,bytes32,bytes,uint256) => NONDET;
}

// The tracker returns no more than the base asset balance it measured before running its modules.
rule trackerPaymentDoesNotExceedWalletBalance(env e, uint256 walletBalance, bytes32 action, bytes data) {
    require e.msg.sender == currentContract;
    currentContract.setWalletBaseAssetBalance(e, walletBalance);
    uint256 balanceBefore = currentContract.balanceOf(e, currentContract);

    uint256 payment;
    address collector;
    payment, collector = currentContract.reportAction(e, action, data);

    assert payment <= balanceBefore;
}
