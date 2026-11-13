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
    return payment;
}

methods {
    function _.baseAsset() external => currentContract expect address ALL;
    function _.balanceOf(address account) external => modeledWalletTokenBalance(account) expect uint256 ALL;
    function _.onAction(address wallet, bytes32 action, bytes data, uint256 maxPayment) external =>
        modeledModulePayment(maxPayment) expect uint256 ALL;
}

// Property 1: whatever the two modules report, the tracker either reverts or never asks for more than the wallet's base-asset balance.
rule trackerPaymentDoesNotExceedWalletBalance(env e, uint256 walletBalance, bytes32 action, bytes data) {
    require e.msg.sender == currentContract;
    require currentContract.moduleCount(e) == 2;
    forceModuleOverpayment = false;
    modeledWalletBaseAssetBalance = walletBalance;
    currentContract.setWalletBaseAssetBalance(e, walletBalance);
    uint256 balanceBefore = currentContract.balanceOf(e, currentContract);

    uint256 payment;
    address collector;
    payment, collector = currentContract.reportAction@withrevert(e, action, data);
    bool reverted = lastReverted;

    assert reverted || payment <= balanceBefore;
    satisfy !reverted && payment > 0 && balanceBefore > 0,
        "modules can take a non-zero payment from a funded wallet";
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

// Property 7: the collector, factory, modules and plans change only through the admin's setters, and wallet plans only through the wallet factory.
rule trackerConfigurationChangesOnlyThroughAuthorisedSetters(method f, bytes32 feeType, address wallet)
filtered {
    f -> !f.isView && f.selector != sig:setWalletBaseAssetBalance(uint256).selector
}
{
    env e;
    calldataarg args;
    address collectorBefore = currentContract.feeCollector(e);
    address factoryBefore = currentContract.walletFactory(e);
    address moduleBefore = currentContract.feeModules(e, feeType);
    uint256 planCountBefore = currentContract.planCount(e, feeType);
    uint256 walletPlanBefore = currentContract.walletPlanId(e, wallet, feeType);
    bool isAdmin = currentContract.hasRole(e, currentContract.DEFAULT_ADMIN_ROLE(e), e.msg.sender);

    f(e, args);

    assert currentContract.feeCollector(e) != collectorBefore => isAdmin && f.selector == sig:setFeeCollector(address).selector;
    assert currentContract.walletFactory(e) != factoryBefore => isAdmin && f.selector == sig:setWalletFactory(address).selector;
    assert currentContract.feeModules(e, feeType) != moduleBefore => isAdmin && f.selector == sig:setFeeModule(bytes32, address).selector;
    assert currentContract.planCount(e, feeType) != planCountBefore => isAdmin && f.selector == sig:createPlan(bytes32, bytes).selector;
    assert currentContract.walletPlanId(e, wallet, feeType) != walletPlanBefore => e.msg.sender == factoryBefore && f.selector == 0x7f9c1528;
}

// Positive control: the admin can change the collector and add a plan, so the rule above can fail.
rule adminCanChangeCollectorAndAddPlan(env e, address newCollector, bytes32 feeType, bytes newPlan) {
    require currentContract.hasRole(e, currentContract.DEFAULT_ADMIN_ROLE(e), e.msg.sender);
    address collectorBefore = currentContract.feeCollector(e);
    uint256 planCountBefore = currentContract.planCount(e, feeType);
    currentContract.setFeeCollector(e, newCollector);
    currentContract.createPlan(e, feeType, newPlan);
    satisfy currentContract.feeCollector(e) != collectorBefore && currentContract.planCount(e, feeType) != planCountBefore;
}

// Property 7: each admin setter stores exactly the value it was given.
rule adminSettersStoreWhatTheyAreGiven(env e, address newCollector, address newFactory, bytes32 feeType, address module) {
    currentContract.setFeeCollector(e, newCollector);
    currentContract.setWalletFactory(e, newFactory);
    currentContract.setFeeModule(e, feeType, module);

    assert currentContract.feeCollector(e) == newCollector;
    assert currentContract.walletFactory(e) == newFactory;
    assert currentContract.feeModules(e, feeType) == module;
}

// Property 1: plugging in a module for a new fee type adds it to the modules every action runs through; replacing
// the module of an existing fee type keeps the list the same length.
rule setFeeModuleAddsNewTypesAndReplacesExistingOnes(env e, bytes32 feeType, address module) {
    bool isNewType = currentContract.feeModules(e, feeType) == 0;
    uint256 countBefore = currentContract.moduleCount(e);

    currentContract.setFeeModule(e, feeType, module);

    assert currentContract.moduleCount(e) == (isNewType ? countBefore + 1 : countBefore);
    satisfy !isNewType;
}
