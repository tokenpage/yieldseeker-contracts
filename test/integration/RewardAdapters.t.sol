// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {ClaimDeliveryMismatch} from "../../src/adapters/MerklAdapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IAWKMerklAdapter} from "../../src/agentwalletkit/adapters/AWKMerklAdapter.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev A reward token whose transfer to `recipient` pulls `amount` of another token into it from `injector`: any
///      inflow that reaches a wallet while it is claiming
contract InflowHookToken is ERC20 {
    IERC20 public immutable INFLOW_TOKEN;
    address public immutable INJECTOR;
    address public recipient;
    uint256 public amount;

    constructor(IERC20 inflowToken, address injector) ERC20("Hook Reward", "HOOK") {
        INFLOW_TOKEN = inflowToken;
        INJECTOR = injector;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function arm(address recipient_, uint256 amount_) external {
        recipient = recipient_;
        amount = amount_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (amount > 0 && from != address(0) && to == recipient) {
            uint256 inflow = amount;
            amount = 0;
            require(INFLOW_TOKEN.transferFrom(INJECTOR, to, inflow));
        }
    }
}

/// @dev Like Merkl's pull token wrappers: what the distributor sends is burnt and the underlying is paid from `holder`
contract BurnOnReceiptWrapper is ERC20 {
    IERC20 public immutable UNDERLYING;
    address public immutable HOLDER;
    address public immutable DISTRIBUTOR;

    constructor(IERC20 underlying, address holder, address distributor) ERC20("Wrapped Reward", "WREW") {
        UNDERLYING = underlying;
        HOLDER = holder;
        DISTRIBUTOR = distributor;
    }

    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == DISTRIBUTOR) {
            _burn(to, value);
            require(UNDERLYING.transferFrom(HOLDER, to, value));
        }
    }
}

contract RewardAdaptersTest is IntegrationBase {
    function _merklCall(address[] memory tokens, uint256[] memory amounts) private view returns (bytes memory) {
        bytes32[][] memory proofs = new bytes32[][](tokens.length);
        for (uint256 i; i < proofs.length; ++i) {
            proofs[i] = new bytes32[](0);
        }
        return abi.encodeCall(IAWKMerklAdapter.claim, (tokens, amounts, proofs));
    }

    function testMerklClaimsBaseRewardsImmediatelyAndDeduplicatesRewardTokenAccounting() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(rewardToken);
        tokens[2] = address(rewardToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 500e6;
        amounts[1] = 100e18;
        amounts[2] = 100e18;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));

        uint256 baseFee = amounts[0] * YIELD_FEE_BPS / 10_000;
        assertEq(usdc.balanceOf(address(wallet)), amounts[0] - baseFee);
        assertEq(rewardToken.balanceOf(address(wallet)), amounts[1]);
        assertEq(_feesCollected(address(usdc)), baseFee);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), amounts[0] - baseFee);
    }

    function testMerklSecondClaimIsChargedOnlyOnTheIncrease() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500e6;
        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));
        amounts[0] = 800e6;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));

        assertEq(_feesCollected(address(usdc)), 800e6 * YIELD_FEE_BPS / 10_000);
        assertEq(usdc.balanceOf(address(wallet)), 800e6 - 800e6 * YIELD_FEE_BPS / 10_000);
    }

    function testMerklBaseAssetListedTwiceIsChargedOnce() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e6;
        amounts[1] = 500e6;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));

        assertEq(_feesCollected(address(usdc)), 50e6);
        assertEq(usdc.balanceOf(address(wallet)), 450e6);
    }

    function testMerklBaseAssetArrivingMidClaimIsNotChargedAsYield() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address injector = makeAddr("injector");
        uint256 inflow = 10_000e6;
        uint256 reward = 1e6;
        InflowHookToken hookToken = new InflowHookToken(IERC20(address(usdc)), injector);
        hookToken.mint(address(merklDistributor), 1e18);
        hookToken.arm(address(wallet), inflow);
        _fund(address(usdc), injector, inflow);
        vm.prank(injector);
        usdc.approve(address(hookToken), inflow);
        address[] memory tokens = new address[](2);
        tokens[0] = address(hookToken);
        tokens[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = reward;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));

        uint256 fee = Math.mulDiv(reward, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        assertEq(_feesCollected(address(usdc)), fee);
        assertEq(usdc.balanceOf(address(wallet)), inflow + reward - fee);
        assertEq(hookToken.balanceOf(address(wallet)), 1e18);
    }

    function testMerklClaimsOfOnlyNonBaseTokensDoNotChargeYieldFees() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken);
        tokens[1] = address(rewardToken);
        tokens[2] = address(rewardToken);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 100e18;
        amounts[2] = 100e18;

        _execute(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts));

        assertEq(rewardToken.balanceOf(address(wallet)), amounts[0]);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(_feesCollected(address(usdc)), 0);
    }

    function testMerklClaimFailureRevertsTheWalletAction() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        merklDistributor.setShouldRevert(true);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;
        bytes memory expectedError = abi.encodeWithSignature("Error(string)", "claim failed");
        _executeExpectRevert(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts), expectedError);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(_feesCollected(address(usdc)), 0);
    }

    function testMerklClaimOfATokenThatDeliversLessThanRecordedReverts() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        address holder = makeAddr("campaignHolder");
        BurnOnReceiptWrapper wrapper = new BurnOnReceiptWrapper(IERC20(address(usdc)), holder, address(merklDistributor));
        wrapper.mint(address(merklDistributor), 1_000e6);
        _fund(address(usdc), holder, 1_000e6);
        vm.prank(holder);
        usdc.approve(address(wrapper), 1_000e6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(wrapper);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1_000e6;
        bytes memory expectedError = abi.encodeWithSelector(ClaimDeliveryMismatch.selector, address(wrapper), 1_000e6, 0);
        _executeExpectRevert(wallet, address(merklAdapter), address(merklDistributor), _merklCall(tokens, amounts), expectedError);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }
}
