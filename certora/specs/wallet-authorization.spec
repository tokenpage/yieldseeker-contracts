using AgentWalletHarness as wallet;

methods {
    // Adapter code is unconstrained, but onlyExecutors protects the only calls into its delegatecall.
    function _.execute(address, bytes) external => HAVOC_ALL;
}

// Property 7: an untrusted caller cannot alter wallet controls or reduce balances; syncFromFactory is intentionally public.
rule untrustedCallerCannotChangeWalletAuthorityOrReduceBalances(method f) {
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

    require !f.isView;
    require f.selector != sig:syncFromFactory().selector;
    require f.selector != sig:recordBaseAssetTransfer(address,address,uint256).selector;
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

