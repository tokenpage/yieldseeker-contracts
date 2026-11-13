methods {
    // The ERC-1271 owner check and any other call out of the wallet returns an arbitrary value; the harness is its
    // own registry and calls itself to build call data, and those calls run the real code.
    unresolved external in _._ => DISPATCH [
        AgentWalletHarness.validateSignature(bytes, bytes, bytes, bytes32),
        AgentWalletHarness.getTargetAdapter(address)
    ] default NONDET;
    // Adapter code runs after the checks these rules are about; it may change anything.
    function _.execute(address, bytes) external => HAVOC_ALL;
    function _.getTargetAdapter(address) external => DISPATCHER(true);
}

definition isAdapterSelector(bytes4 selector) returns bool =
    selector == to_bytes4(sig:executeViaAdapter(address, address, bytes).selector) ||
    selector == to_bytes4(sig:executeViaAdapterBatch(address[], address[], bytes[]).selector);

// Property 6: an adapter-execution UserOp validates exactly when the owner signed it, or a current operator signed it
// and a paymaster (non-zero address) sponsors it. The owner's ERC-1271 approval is never consulted for these calls.
rule adapterCallSignaturesValidateOnlyForTheOwnerOrASponsoredOperator(env e, bytes signature, bytes4 selector, bytes arguments, address paymaster, bytes paymasterData, bytes32 userOpHash) {
    require isAdapterSelector(selector);
    address walletOwner = currentContract.owner(e);
    address signer = currentContract.recoverSigner(e, userOpHash, signature);

    uint256 result = currentContract.validateCall(e, signature, selector, arguments, paymaster, paymasterData, userOpHash);

    bool ownerSigned = signer != 0 && signer == walletOwner;
    bool sponsoredOperator = signer != 0 && paymaster != 0 && currentContract.isAgentOperator(e, signer);
    assert result == 0 <=> (ownerSigned || sponsoredOperator);
    assert result == 0 || result == 1;
    satisfy sponsoredOperator && !ownerSigned;
}

// Property 6: any other UserOp validates only with the owner's signature (the owner here has no code, so ERC-1271
// does not apply). Operators can never authorize withdrawals, upgrades or blocklist changes.
rule otherCallSignaturesValidateOnlyForTheOwner(env e, bytes signature, bytes4 selector, bytes arguments, address paymaster, bytes paymasterData, bytes32 userOpHash) {
    require !isAdapterSelector(selector);
    address walletOwner = currentContract.owner(e);
    require nativeCodesize[walletOwner] == 0;
    address signer = currentContract.recoverSigner(e, userOpHash, signature);

    uint256 result = currentContract.validateCall(e, signature, selector, arguments, paymaster, paymasterData, userOpHash);

    assert result == 0 <=> (signer != 0 && signer == walletOwner);
    satisfy result == 0;
}

// Property 6: with call data shorter than a selector or paymaster data shorter than an address, only the owner validates.
rule shortCallDataOrPaymasterValidatesOnlyForTheOwner(env e, bytes signature, bytes callData, bytes paymasterAndData, bytes32 userOpHash) {
    require callData.length < 4 || paymasterAndData.length < 20;
    address walletOwner = currentContract.owner(e);
    require nativeCodesize[walletOwner] == 0;
    address signer = currentContract.recoverSigner(e, userOpHash, signature);

    uint256 result = currentContract.validateSignature(e, signature, callData, paymasterAndData, userOpHash);

    assert result == 0 => signer != 0 && signer == walletOwner;
}

// Property 10: an adapter runs only when the caller is an executor, the registry maps the target to that adapter, and
// the owner has blocked neither.
rule adaptersRunOnlyWhenRegisteredUnblockedAndCalledByAnExecutor(env e, address adapter, address target, bytes data) {
    require currentContract.adapterRegistry(e) == currentContract;
    bool registered = adapter != 0 && currentContract.registeredAdapterFor(e, target) == adapter;
    bool unblocked = !currentContract.isAdapterBlocked(e, adapter) && !currentContract.isTargetBlocked(e, target);
    bool executor = e.msg.sender == currentContract.owner(e) || currentContract.isEntryPoint(e, e.msg.sender) || currentContract.isAgentOperator(e, e.msg.sender);

    currentContract.executeViaAdapter@withrevert(e, adapter, target, data);

    assert !lastReverted => registered && unblocked && executor;
    satisfy !lastReverted;
}

// Property 10: a batch needs matching array lengths, and its first call obeys the same checks.
rule adapterBatchesNeedMatchingArraysAndRegisteredUnblockedAdapters(env e, address[] adapters, address[] targets, bytes[] datas) {
    require currentContract.adapterRegistry(e) == currentContract;
    require adapters.length > 0 && targets.length > 0;
    bool registered = adapters[0] != 0 && currentContract.registeredAdapterFor(e, targets[0]) == adapters[0];
    bool unblocked = !currentContract.isAdapterBlocked(e, adapters[0]) && !currentContract.isTargetBlocked(e, targets[0]);

    currentContract.executeViaAdapterBatch@withrevert(e, adapters, targets, datas);

    assert !lastReverted => adapters.length == targets.length && adapters.length == datas.length;
    assert !lastReverted => registered && unblocked;
    satisfy !lastReverted;
}
