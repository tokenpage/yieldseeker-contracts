using AgentWalletHarness as wallet;

methods {
    // Adapter code is unconstrained, but onlyExecutors protects the only calls into its delegatecall.
    function _.execute(address, bytes) external => HAVOC_ALL;
}

// Property 7: an untrusted caller cannot alter wallet controls or reduce balances; syncFromFactory is intentionally public.
rule untrustedCallerCannotChangeWalletAuthorityOrReduceBalances(method f)
filtered {
    f ->
        !f.isView &&
        f.selector != sig:syncFromFactory().selector &&
        f.selector != sig:recordBaseAssetTransfer(address,address,uint256).selector
}
{
    env e;
    calldataarg args;
    address operatorProbe;
    address adapterProbe;
    address targetProbe;

    address walletAddress = currentContract;
    address ownerBefore = currentContract.owner(e);
    address registryBefore = currentContract.adapterRegistry(e);
    bool operatorBefore = currentContract.isAgentOperator(e, operatorProbe);
    bool adapterBlockedBefore = currentContract.isAdapterBlocked(e, adapterProbe);
    bool targetBlockedBefore = currentContract.isTargetBlocked(e, targetProbe);
    address implementationBefore = currentContract.currentImplementation(e);
    uint256 baseAssetBalanceBefore = currentContract.balanceOf(e, walletAddress);
    mathint nativeBalanceBefore = nativeBalances[walletAddress];

    require currentContract.walletInitialized(e);
    require ownerBefore != 0;
    require e.msg.sender != ownerBefore;
    require !currentContract.isEntryPoint(e, e.msg.sender);
    require !currentContract.isAgentOperator(e, e.msg.sender);

    wallet.f@withrevert(e, args);

    assert lastReverted ||
        (currentContract.owner(e) == ownerBefore &&
        currentContract.adapterRegistry(e) == registryBefore &&
        currentContract.isAgentOperator(e, operatorProbe) == operatorBefore &&
        currentContract.isAdapterBlocked(e, adapterProbe) == adapterBlockedBefore &&
        currentContract.isTargetBlocked(e, targetProbe) == targetBlockedBefore &&
        currentContract.currentImplementation(e) == implementationBefore &&
        currentContract.balanceOf(e, walletAddress) >= baseAssetBalanceBefore &&
        nativeBalances[walletAddress] >= nativeBalanceBefore);
}

// Reachability witness: each covered method admits a model with a consistent untrusted caller.
rule untrustedCallerCanInvokeEachCoveredMethod(method f)
filtered {
    f ->
        !f.isView &&
        f.selector != sig:syncFromFactory().selector &&
        f.selector != sig:recordBaseAssetTransfer(address,address,uint256).selector
}
{
    env e;
    calldataarg args;
    address ownerBefore = currentContract.owner(e);

    require currentContract.walletInitialized(e);
    require ownerBefore != 0;
    require e.msg.sender != ownerBefore;
    require !currentContract.isEntryPoint(e, e.msg.sender);
    require !currentContract.isAgentOperator(e, e.msg.sender);

    wallet.f@withrevert(e, args);
    satisfy true, "the untrusted caller reaches this covered method with consistent preconditions";
}


// Positive control: the owner can change both user blocklists through the guarded wallet methods.
rule ownerCanChangeWalletBlocklists(env e, address adapterProbe, address targetProbe) {
    address ownerBefore = currentContract.owner(e);
    require currentContract.walletInitialized(e);
    require ownerBefore != 0;
    require e.msg.sender == ownerBefore;
    require !currentContract.isAdapterBlocked(e, adapterProbe);
    require !currentContract.isTargetBlocked(e, targetProbe);

    currentContract.blockAdapter(e, adapterProbe);
    currentContract.blockTarget(e, targetProbe);
    satisfy currentContract.isAdapterBlocked(e, adapterProbe) &&
        currentContract.isTargetBlocked(e, targetProbe);
}

// Positive control: the owner can reduce the wallet's native-asset balance through its withdrawal method.
rule ownerCanWithdrawNativeAsset(env e, address recipient) {
    address ownerBefore = currentContract.owner(e);
    address walletAddress = currentContract;
    mathint balanceBefore = nativeBalances[walletAddress];
    require currentContract.walletInitialized(e);
    require ownerBefore != 0;
    require e.msg.sender == ownerBefore;
    require recipient != 0 && recipient != walletAddress;
    require balanceBefore > 0;

    currentContract.withdrawEthToUser(e, recipient, 1);
    satisfy nativeBalances[walletAddress] < balanceBefore,
        "the owner withdrawal reduces the native-asset balance";
}

