using AgentWalletHarness as wallet;

methods {
    // Calls the wallet makes to the factory, tokens and the EntryPoint return arbitrary values but do not call back
    // into the wallet: the withdrawals are nonReentrant and the factory is admin-controlled and only read.
    unresolved external in _._ => DISPATCH [] default NONDET;
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
