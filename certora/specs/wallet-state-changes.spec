using AgentWalletHarness as wallet;
using MockBaseAsset as token;

methods {
    // Calls the wallet makes to the factory, tokens and the EntryPoint return arbitrary values but do not call back
    // into the wallet: the withdrawals are nonReentrant and the factory is admin-controlled and only read.
    unresolved external in _._ => DISPATCH [
        MockBaseAsset.balanceOf(address),
        MockBaseAsset.transfer(address, uint256)
    ] default NONDET;
    function MockBaseAsset.balanceOf(address) external returns (uint256) envfree;
    function _.balanceOf(address) external => DISPATCHER(true);
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.feesOwedInBaseAsset(address account) external => modeledFeesOwed[account] expect uint256;
    function _.reportAction(bytes32, bytes) external => noFeesDue() expect (uint256, address);
}

ghost mapping(address => uint256) modeledFeesOwed;

function noFeesDue() returns (uint256, address) {
    address collector;
    return (0, collector);
}

// Excluded: registered adapters and the owner's own arbitrary calls run trusted code inside the wallet; initialize
// always reverts on an initialized wallet; the harness is not a proxy, so the upgrade functions always revert here
// (upgrade authorization is covered by the Foundry tests on real proxies).
definition covered(method f) returns bool =
    !f.isView && f.contract == wallet &&
    f.selector != sig:executeViaAdapter(address, address, bytes).selector &&
    f.selector != sig:executeViaAdapterBatch(address[], address[], bytes[]).selector &&
    f.selector != sig:execute(address, uint256, bytes).selector &&
    f.selector != sig:executeBatch(address[], bytes[]).selector &&
    f.selector != sig:initialize(address, uint256, address, bytes32).selector &&
    f.selector != sig:initialize(address, uint256, bytes32).selector &&
    f.selector != sig:upgradeToAndCall(address, bytes).selector &&
    f.selector != sig:upgradeToLatest().selector;

// Property 7, any caller: once initialized, nothing changes the owner.
rule walletOwnerNeverChanges(method f) filtered { f -> covered(f) } {
    env e;
    calldataarg args;
    address ownerBefore = currentContract.owner(e);
    require currentContract.walletInitialized(e);

    wallet.f(e, args);

    assert currentContract.owner(e) == ownerBefore;
}

// Property 7, any caller: the registry and operators change only through syncFromFactory, which copies the factory's admin-set values.
rule walletRegistryAndOperatorsChangeOnlyThroughSync(method f, address operatorProbe) filtered { f -> covered(f) } {
    env e;
    calldataarg args;
    address registryBefore = currentContract.adapterRegistry(e);
    bool operatorBefore = currentContract.isAgentOperator(e, operatorProbe);
    require currentContract.walletInitialized(e);

    wallet.f(e, args);

    bool changed = currentContract.adapterRegistry(e) != registryBefore || currentContract.isAgentOperator(e, operatorProbe) != operatorBefore;
    assert changed => f.selector == sig:syncFromFactory().selector;
}

// Property 7, any caller: blocklists change only through the owner's block and unblock functions.
rule walletBlocklistsChangeOnlyByOwner(method f, address adapterProbe, address targetProbe) filtered { f -> covered(f) } {
    env e;
    calldataarg args;
    bool adapterBlockedBefore = currentContract.isAdapterBlocked(e, adapterProbe);
    bool targetBlockedBefore = currentContract.isTargetBlocked(e, targetProbe);
    bool ownerOrEntryPoint = e.msg.sender == currentContract.owner(e) || currentContract.isEntryPoint(e, e.msg.sender);
    require currentContract.walletInitialized(e);

    wallet.f(e, args);

    bool changed = currentContract.isAdapterBlocked(e, adapterProbe) != adapterBlockedBefore || currentContract.isTargetBlocked(e, targetProbe) != targetBlockedBefore;
    assert changed => ownerOrEntryPoint && (
        f.selector == sig:blockAdapter(address).selector || f.selector == sig:unblockAdapter(address).selector ||
        f.selector == sig:blockTarget(address).selector || f.selector == sig:unblockTarget(address).selector);
}

// Positive control: a factory sync can change the operator set, so the rule above can fail.
rule syncCanChangeOperators(env e, address operatorProbe) {
    require currentContract.walletInitialized(e);
    bool operatorBefore = currentContract.isAgentOperator(e, operatorProbe);
    currentContract.syncFromFactory(e);
    satisfy currentContract.isAgentOperator(e, operatorProbe) != operatorBefore;
}

// Property 9: the withdrawable base asset is the balance less the fees owed, never below zero.
rule withdrawableBalanceIsTheBaseAssetLessFeesOwed(env e) {
    address walletAddress = currentContract;
    require currentContract.baseAsset(e) == token;
    uint256 balance = token.balanceOf(walletAddress);
    uint256 owed = modeledFeesOwed[walletAddress];

    assert currentContract.withdrawableBalance(e, token) == (balance > owed ? balance - owed : 0);
}

// Property 8: with no fees to settle, an owner withdrawal of up to the balance never reverts and moves exactly the amount.
rule ownerWithdrawalMovesExactlyTheAmount(env e, address recipient, uint256 amount) {
    address walletAddress = currentContract;
    require currentContract.walletInitialized(e);
    require currentContract.baseAsset(e) == token;
    require e.msg.sender == currentContract.owner(e);
    require e.msg.value == 0;
    require !currentContract.reentrancyGuardEntered(e);
    require recipient != 0 && recipient != walletAddress;
    uint256 walletBefore = token.balanceOf(walletAddress);
    uint256 recipientBefore = token.balanceOf(recipient);
    require amount > 0 && amount <= walletBefore;
    require recipientBefore + amount <= max_uint256;

    currentContract.withdrawAssetToUser@withrevert(e, recipient, token, amount);

    assert !lastReverted;
    assert token.balanceOf(walletAddress) == walletBefore - amount;
    assert token.balanceOf(recipient) == recipientBefore + amount;
}

// Positive control: an operator can run a registered adapter, so onlyExecutors does not reject everyone.
rule operatorCanRunAnAdapter(env e, address adapter, address target, bytes data) {
    require currentContract.walletInitialized(e);
    require currentContract.isAgentOperator(e, e.msg.sender);
    require e.msg.value == 0;
    require !currentContract.reentrancyGuardEntered(e);

    currentContract.executeViaAdapter@withrevert(e, adapter, target, data);

    satisfy !lastReverted;
}
