// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {SwapInputMismatch} from "../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {IntegrationBase} from "../integration/IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

/// @dev Stands in for code a compromised operator runs mid-swap (e.g. a token hook on its own route): it submits an
///      owner-signed UserOperation it holds to the v0.6 EntryPoint, which anyone may call
contract NestedUserOpHook {
    IEntryPoint internal constant ENTRY_POINT = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
    bytes internal pendingOp;

    receive() external payable {}

    function setPendingOp(UserOperation calldata op) external {
        pendingOp = abi.encode(op);
    }

    function onHop() external {
        if (pendingOp.length == 0) return;
        bytes memory encoded = pendingOp;
        delete pendingOp;
        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = abi.decode(encoded, (UserOperation));
        ENTRY_POINT.handleOps(ops, payable(address(this)));
    }
}

contract HookedSwapRouter {
    NestedUserOpHook public immutable HOOK;
    uint256 public buyAmount;

    constructor(NestedUserOpHook hook) {
        HOOK = hook;
    }

    function setBuyAmount(uint256 amount) external {
        buyAmount = amount;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256) {
        address sellToken = address(bytes20(params.path[:20]));
        address buyToken = address(bytes20(params.path[params.path.length - 20:]));
        require(IERC20(sellToken).transferFrom(msg.sender, address(this), params.amountIn), "pull");
        HOOK.onHop();
        require(IERC20(buyToken).transfer(params.recipient, buyAmount), "pay");
        return buyAmount;
    }
}

/// @dev Uses the canonical v0.6 EntryPoint on Base: an owner withdrawal into the swapping wallet, run from inside the
///      swap, must not count as the swap's output or input
contract NestedOwnerOpMidSwapForkTest is IntegrationBase {
    using MessageHashUtils for bytes32;

    IEntryPoint internal constant ENTRY_POINT_V06 = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);

    address internal alice;
    uint256 internal aliceKey;
    NestedUserOpHook internal hook;
    HookedSwapRouter internal router;
    YieldSeekerUniswapV3SwapAdapter internal hookedAdapter;

    function setUp() public override {
        if (block.chainid != 8453) vm.skip(true);
        super.setUp();
        (alice, aliceKey) = makeAddrAndKey("alice");
        hook = new NestedUserOpHook();
        router = new HookedSwapRouter(hook);
        hookedAdapter = new YieldSeekerUniswapV3SwapAdapter(address(router));
        _registerTarget(vaultRegistry, address(router), address(hookedAdapter));
        _registerTarget(borrowRegistry, address(router), address(hookedAdapter));
    }

    function test_OwnerWithdrawalRunMidRewardSaleIsNotChargedAsYield() public {
        AgentWallet seller = _createVaultWallet(alice, 1);
        AgentWallet source = _createVaultWallet(alice, 2);
        uint256 moved = 10_000e6;
        _fundWallet(seller, address(rewardToken), 10e18);
        _fundWallet(source, address(usdc), moved);
        vm.deal(address(source), 1 ether);
        _fund(address(usdc), address(router), 1e6);
        router.setBuyAmount(1e6);
        hook.setPendingOp(_ownerOp(source, abi.encodeCall(source.withdrawAssetToUser, (address(seller), address(usdc), moved))));

        uint256 feesBefore = _feesCollected(address(usdc));
        _execute(seller, address(hookedAdapter), address(router), abi.encodeCall(hookedAdapter.swap, (address(rewardToken), address(usdc), _route(address(rewardToken), address(usdc)), 10e18, uint256(1), block.timestamp)));

        assertEq(usdc.balanceOf(address(source)), 0);
        assertEq(_feesCollected(address(usdc)) - feesBefore, Math.mulDiv(1e6, YIELD_FEE_BPS, 1e4, Math.Rounding.Ceil));
        assertEq(usdc.balanceOf(address(seller)), moved + 1e6 - Math.mulDiv(1e6, YIELD_FEE_BPS, 1e4, Math.Rounding.Ceil));
    }

    function test_OwnerWithdrawalRunMidBorrowSwapCannotLowerTheOracleFloor() public {
        AgentWallet borrower = _createBorrowWallet(alice, 1);
        AgentWallet source = _createVaultWallet(alice, 2);
        _borrowWeth(borrower, 3_000e6, 1e18);
        vm.prank(alice);
        borrower.withdrawAllAssetToUser(alice, address(weth));
        uint256 sold = 10_000e6;
        uint256 moved = 9_000e6;
        _fundWallet(borrower, address(usdc), sold);
        _fundWallet(source, address(usdc), moved);
        vm.deal(address(source), 1 ether);
        uint256 paid = _floor(sold - moved);
        _fund(address(weth), address(router), paid);
        router.setBuyAmount(paid);
        hook.setPendingOp(_ownerOp(source, abi.encodeCall(source.withdrawAssetToUser, (address(borrower), address(usdc), moved))));

        bytes memory data = abi.encodeCall(hookedAdapter.swap, (address(usdc), address(weth), _route(address(usdc), address(weth)), sold, uint256(1), block.timestamp));
        _executeExpectRevert(borrower, address(hookedAdapter), address(router), data, abi.encodeWithSelector(SwapInputMismatch.selector, sold - moved, sold));

        assertEq(usdc.balanceOf(address(borrower)), sold);
        assertEq(usdc.balanceOf(address(source)), moved);
        assertEq(weth.balanceOf(address(borrower)), 0);
    }

    function _ownerOp(AgentWallet wallet, bytes memory callData) internal view returns (UserOperation memory op) {
        op = UserOperation({
            sender: address(wallet),
            nonce: ENTRY_POINT_V06.getNonce(address(wallet), 0),
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 100_000,
            maxFeePerGas: 10 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, ENTRY_POINT_V06.getUserOpHash(op).toEthSignedMessageHash());
        op.signature = abi.encodePacked(r, s, v);
    }

    function _borrowWeth(AgentWallet wallet, uint256 collateralAmount, uint256 borrowedAmount) private {
        _fundWallet(wallet, address(usdc), collateralAmount);
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount)));
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowedAmount)));
    }

    function _floor(uint256 amountIn) private view returns (uint256) {
        return Math.mulDiv(priceOracle.quote(address(usdc), address(weth), amountIn), 1e4 - BORROW_SWAP_MAX_SLIPPAGE_BPS, 1e4, Math.Rounding.Ceil);
    }

    function _route(address from, address to) private pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
    }
}
