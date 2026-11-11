ghost uint256 modeledWalletBaseAssetBalance;

function modeledWalletTokenBalance(address account) returns (uint256) {
    return account == currentContract ? modeledWalletBaseAssetBalance : 0;
}

ghost bool forceModuleOverpayment;

function modeledModulePayment(uint256 maxPayment) returns (uint256) {
    if (forceModuleOverpayment) {
        return max_uint256;
    }
    uint256 payment;
    require payment <= maxPayment;
    return payment;
}

methods {
    function _.baseAsset() external => currentContract expect address ALL;
    function _.balanceOf(address account) external => modeledWalletTokenBalance(account) expect uint256 ALL;
    function _.onAction(address wallet, bytes32 action, bytes data, uint256 maxPayment) external =>
        modeledModulePayment(maxPayment) expect uint256 ALL;
}

// Property 1: the two-module tracker stays within the wallet's modeled base-asset balance when each callback stays within its allowance.
rule trackerPaymentDoesNotExceedWalletBalance(env e, uint256 walletBalance, bytes32 action, bytes data) {
    require e.msg.sender == currentContract;
    require currentContract.moduleCount(e) == 2;
    forceModuleOverpayment = false;
    modeledWalletBaseAssetBalance = walletBalance;
    currentContract.setWalletBaseAssetBalance(e, walletBalance);
    uint256 balanceBefore = currentContract.balanceOf(e, currentContract);

    uint256 payment;
    address collector;
    payment, collector = currentContract.reportAction(e, action, data);

    assert payment <= balanceBefore;
    satisfy payment > 0 && balanceBefore > 0,
        "a bounded module can report a non-zero payment from a funded wallet";
}

// Property 1: a module that reports more than the remaining allowance makes the tracker revert, provided that balance is below max uint256.
rule trackerRejectsModuleOverpayment(env e, uint256 walletBalance, bytes32 action, bytes data) {
    require e.msg.sender == currentContract;
    require currentContract.moduleCount(e) == 2;
    require walletBalance < max_uint256;
    forceModuleOverpayment = true;
    modeledWalletBaseAssetBalance = walletBalance;
    currentContract.setWalletBaseAssetBalance(e, walletBalance);

    currentContract.reportAction@withrevert(e, action, data);

    assert lastReverted;
    satisfy lastReverted, "forced module overpayment reaches the tracker rejection";
}
