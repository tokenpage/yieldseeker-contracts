methods {
    function getEthBalance(address) external returns (uint256) envfree;
    unresolved external in _.executeViaAdapter(address,address,bytes) => HAVOC_ALL;
    unresolved external in _.executeViaAdapterBatch(address[],address[],bytes[]) => HAVOC_ALL;
}

// An untrusted caller cannot alter wallet authority, routing controls, implementation, or balances.
rule untrustedCallerCannotChangeWalletAuthorityOrReduceBalances(method f) {
    env e;
    calldataarg args;
    address operatorProbe;
    address adapterProbe;
    address targetProbe;

    address wallet = currentContract;
    address ownerBefore = currentContract.owner(e);
    address registryBefore = address(currentContract.adapterRegistry(e));
    bool operatorBefore = currentContract.isAgentOperator(e, operatorProbe);
    bool adapterBlockedBefore = currentContract.isAdapterBlocked(e, adapterProbe);
    bool targetBlockedBefore = currentContract.isTargetBlocked(e, targetProbe);
    bytes32 operatorsBefore = currentContract.operatorListHash(e);
    address implementationBefore = currentContract.currentImplementation(e);
    uint256 baseAssetBalanceBefore = currentContract.balanceOf(e, wallet);
    mathint nativeBalanceBefore = getEthBalance(wallet);

    require e.msg.sender != ownerBefore;
    require !currentContract.isEntryPoint(e, e.msg.sender);
    require !currentContract.isAgentOperator(e, e.msg.sender);

    f@withrevert(e, args);

    if (!lastReverted) {
        assert currentContract.owner(e) == ownerBefore;
        assert address(currentContract.adapterRegistry(e)) == registryBefore;
        assert currentContract.isAgentOperator(e, operatorProbe) == operatorBefore;
        assert currentContract.isAdapterBlocked(e, adapterProbe) == adapterBlockedBefore;
        assert currentContract.isTargetBlocked(e, targetProbe) == targetBlockedBefore;
        assert currentContract.operatorListHash(e) == operatorsBefore;
        assert currentContract.currentImplementation(e) == implementationBefore;
        assert currentContract.balanceOf(e, wallet) >= baseAssetBalanceBefore;
        assert getEthBalance(wallet) >= nativeBalanceBefore;
    }
}
