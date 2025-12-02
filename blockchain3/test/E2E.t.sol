// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {ERC4626VaultWrapper} from "../src/vaults/ERC4626VaultWrapper.sol";
import {AaveV3VaultWrapper} from "../src/vaults/AaveV3VaultWrapper.sol";
import {MerklValidator} from "../src/validators/MerklValidator.sol";
import {ZeroExValidator} from "../src/validators/ZeroExValidator.sol";
import {MultiEntryPointAccountERC7579, IEntryPointV06} from "../src/lib/MultiEntryPointAccountERC7579.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault, MockAaveV3Pool, MockAToken} from "./mocks/MockVaults.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IERC7579Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
address constant ENTRYPOINT_V06 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

contract MockEntryPointV08 {
    function handleOps(PackedUserOperation[] calldata ops, address payable) external {
        for (uint256 i = 0; i < ops.length; i++) {
            PackedUserOperation calldata op = ops[i];
            bytes32 opHash = getUserOpHash(op);
            uint256 validationData = YieldSeekerAgentWallet(payable(op.sender)).validateUserOp(op, opHash, 0);
            require(validationData == 0, "Invalid UserOp");
            (bool success,) = op.sender.call(op.callData);
            require(success, "Execution failed");
        }
    }

    function getUserOpHash(PackedUserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce, keccak256(userOp.initCode), keccak256(userOp.callData), userOp.accountGasLimits, userOp.preVerificationGas, userOp.gasFees, keccak256(userOp.paymasterAndData), block.chainid, address(this)));
    }

    function getUserOpHashMemory(PackedUserOperation memory userOp) public view returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce, keccak256(userOp.initCode), keccak256(userOp.callData), userOp.accountGasLimits, userOp.preVerificationGas, userOp.gasFees, keccak256(userOp.paymasterAndData), block.chainid, address(this)));
    }

    receive() external payable {}
}

contract MockEntryPointV06 {
    function handleOps(IEntryPointV06.UserOperation[] calldata ops, address payable) external {
        for (uint256 i = 0; i < ops.length; i++) {
            IEntryPointV06.UserOperation calldata op = ops[i];
            bytes32 opHash = getUserOpHash(op);
            uint256 validationData = YieldSeekerAgentWallet(payable(op.sender)).validateUserOp(op, opHash, 0);
            require(validationData == 0, "Invalid UserOp");
            (bool success,) = op.sender.call(op.callData);
            require(success, "Execution failed");
        }
    }

    function getUserOpHash(IEntryPointV06.UserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce, keccak256(userOp.initCode), keccak256(userOp.callData), userOp.callGasLimit, userOp.verificationGasLimit, userOp.preVerificationGas, userOp.maxFeePerGas, userOp.maxPriorityFeePerGas, keccak256(userOp.paymasterAndData), block.chainid, address(this)));
    }

    function getUserOpHashMemory(IEntryPointV06.UserOperation memory userOp) public view returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce, keccak256(userOp.initCode), keccak256(userOp.callData), userOp.callGasLimit, userOp.verificationGasLimit, userOp.preVerificationGas, userOp.maxFeePerGas, userOp.maxPriorityFeePerGas, keccak256(userOp.paymasterAndData), block.chainid, address(this)));
    }

    receive() external payable {}
}

contract MockMerklDistributor {
    // The real Merkl Distributor uses selector 0x3d13f874
    // claim(address[] users, address[] tokens, uint256[] amounts, bytes32[][] proofs)
    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        require(selector == bytes4(0x3d13f874), "Invalid selector");
        (address[] memory users, address[] memory tokens, uint256[] memory amounts,) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
        for (uint256 i = 0; i < users.length; i++) {
            MockERC20(tokens[i]).mint(users[i], amounts[i]);
        }
        return "";
    }
}

contract MockZeroExRouter {
    MockERC20 public outputToken;

    function setOutputToken(address _outputToken) external {
        outputToken = MockERC20(_outputToken);
    }

    // The real ZeroEx uses selector 0x415565b0 for transformERC20
    // transformERC20(address inputToken, address outputToken, uint256 inputAmount, uint256 minOutputAmount, (uint32,bytes)[] transformations)
    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        require(selector == bytes4(0x415565b0), "Invalid selector");
        (address inputToken, address _outputToken, uint256 inputAmount, uint256 minOutputAmount,) = abi.decode(data[4:], (address, address, uint256, uint256, bytes[]));
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        MockERC20(_outputToken).mint(msg.sender, minOutputAmount);
        return abi.encode(minOutputAmount);
    }
}

contract E2ETest is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    ERC4626VaultWrapper public erc4626Wrapper;
    AaveV3VaultWrapper public aaveWrapper;
    MerklValidator public merklValidator;
    ZeroExValidator public zeroExValidator;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockERC20 public rewardToken;
    MockERC4626Vault public yearnVault;
    MockERC4626Vault public morphoVault;
    MockAaveV3Pool public aavePool;
    MockAToken public aUsdc;
    MockMerklDistributor public merklDistributor;
    MockZeroExRouter public zeroExRouter;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x5);
    uint256 public operatorPrivateKey = 0x3;
    address public operator;
    address public randomUser = address(0x4);

    // Cached selectors (computed in setUp to avoid consuming vm.prank)
    bytes4 public ERC4626_DEPOSIT;
    bytes4 public ERC4626_WITHDRAW;
    bytes4 public AAVE_DEPOSIT;
    bytes4 public AAVE_WITHDRAW;
    bytes4 public MERKL_CLAIM;
    bytes4 public ZEROEX_TRANSFORM;

    function setUp() public {
        operator = vm.addr(operatorPrivateKey);
        MockEntryPointV08 mockEPV08 = new MockEntryPointV08();
        MockEntryPointV06 mockEPV06 = new MockEntryPointV06();
        vm.etch(ENTRYPOINT_V08, address(mockEPV08).code);
        vm.etch(ENTRYPOINT_V06, address(mockEPV06).code);

        vm.startPrank(admin);

        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);
        factory.setDefaultExecutor(address(router));

        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
        rewardToken = new MockERC20("REWARD", "RWD");

        yearnVault = new MockERC4626Vault(address(usdc), "Yearn USDC", "yvUSDC");
        morphoVault = new MockERC4626Vault(address(usdc), "Morpho USDC", "mUSDC");

        aavePool = new MockAaveV3Pool();
        aUsdc = new MockAToken(address(usdc), "Aave USDC", "aUSDC");
        aUsdc.setPool(address(aavePool));
        aavePool.setAToken(address(usdc), address(aUsdc));
        usdc.mint(address(aavePool), 10_000_000e6);

        erc4626Wrapper = new ERC4626VaultWrapper(admin);
        erc4626Wrapper.addVault(address(yearnVault));
        erc4626Wrapper.addVault(address(morphoVault));
        aaveWrapper = new AaveV3VaultWrapper(address(aavePool), admin);
        aaveWrapper.addAsset(address(usdc), address(aUsdc));

        merklValidator = new MerklValidator();
        zeroExValidator = new ZeroExValidator();

        merklDistributor = new MockMerklDistributor();
        zeroExRouter = new MockZeroExRouter();
        zeroExRouter.setOutputToken(address(usdc));

        // Cache selectors
        ERC4626_DEPOSIT = erc4626Wrapper.DEPOSIT_SELECTOR();
        ERC4626_WITHDRAW = erc4626Wrapper.WITHDRAW_SELECTOR();
        AAVE_DEPOSIT = aaveWrapper.DEPOSIT_SELECTOR();
        AAVE_WITHDRAW = aaveWrapper.WITHDRAW_SELECTOR();
        MERKL_CLAIM = merklValidator.CLAIM_SELECTOR();
        ZEROEX_TRANSFORM = zeroExValidator.TRANSFORM_ERC20_SELECTOR();

        policy.addPolicy(address(erc4626Wrapper), ERC4626_DEPOSIT, address(erc4626Wrapper));
        policy.addPolicy(address(erc4626Wrapper), ERC4626_WITHDRAW, address(erc4626Wrapper));
        policy.addPolicy(address(aaveWrapper), AAVE_DEPOSIT, address(aaveWrapper));
        policy.addPolicy(address(aaveWrapper), AAVE_WITHDRAW, address(aaveWrapper));
        policy.addPolicy(address(merklDistributor), MERKL_CLAIM, address(merklValidator));
        policy.addPolicy(address(zeroExRouter), ZEROEX_TRANSFORM, address(zeroExValidator));
        policy.addPolicy(address(usdc), IERC20.approve.selector, address(1));
        policy.addPolicy(address(weth), IERC20.approve.selector, address(1));
        policy.addPolicy(address(rewardToken), IERC20.approve.selector, address(1));
        policy.addPolicy(address(yearnVault), IERC20.approve.selector, address(1));
        policy.addPolicy(address(morphoVault), IERC20.approve.selector, address(1));
        policy.addPolicy(address(aUsdc), IERC20.approve.selector, address(1));

        vm.stopPrank();
    }

    function entryPointV08() internal pure returns (MockEntryPointV08) {
        return MockEntryPointV08(payable(ENTRYPOINT_V08));
    }

    function entryPointV06() internal pure returns (MockEntryPointV06) {
        return MockEntryPointV06(payable(ENTRYPOINT_V06));
    }

    function _createWallet(address user, uint256 index) internal returns (address) {
        vm.prank(admin);
        return factory.createAgentWallet(user, index, address(usdc));
    }

    function _fundWallet(address wallet, uint256 amount) internal {
        usdc.mint(wallet, amount);
    }

    function _approveWrapper(address wallet, address token, address wrapper) internal {
        bytes memory data = abi.encodeCall(IERC20.approve, (wrapper, type(uint256).max));
        vm.prank(operator);
        router.executeAction(wallet, token, 0, data);
    }

    // ============ Agent Lifecycle Tests ============

    function test_E2E_CreateAgent_FullSetup() public {
        address walletAddr = _createWallet(user1, 0);
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(wallet.user(), user1);
        assertEq(wallet.userAgentIndex(), 0);
        assertEq(wallet.baseAsset(), address(usdc));
        assertEq(wallet.owner(), user1);
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
        assertEq(wallet.accountId(), "yieldseeker.agent.wallet.v1");
    }

    function test_E2E_CreateAgent_MultipleAgentsPerUser() public {
        address wallet0 = _createWallet(user1, 0);
        address wallet1 = _createWallet(user1, 1);
        address wallet2 = _createWallet(user1, 2);
        assertTrue(wallet0 != wallet1);
        assertTrue(wallet1 != wallet2);
        assertEq(YieldSeekerAgentWallet(payable(wallet0)).userAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(wallet1)).userAgentIndex(), 1);
        assertEq(YieldSeekerAgentWallet(payable(wallet2)).userAgentIndex(), 2);
    }

    function test_E2E_CreateAgent_DifferentUsers() public {
        address wallet1Addr = _createWallet(user1, 0);
        address wallet2Addr = _createWallet(user2, 0);
        assertTrue(wallet1Addr != wallet2Addr);
        assertEq(YieldSeekerAgentWallet(payable(wallet1Addr)).user(), user1);
        assertEq(YieldSeekerAgentWallet(payable(wallet2Addr)).user(), user2);
    }

    // ============ ERC4626 Wrapper Tests ============

    function test_E2E_ERC4626_Deposit_ValidVault() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory data = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_ERC4626_Deposit_UnallowedVault_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        MockERC4626Vault unauthorizedVault = new MockERC4626Vault(address(usdc), "Bad Vault", "BAD");
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory data = abi.encodeWithSelector(ERC4626_DEPOSIT, address(unauthorizedVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    function test_E2E_ERC4626_Deposit_AssetMismatch_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        MockERC4626Vault wethVault = new MockERC4626Vault(address(weth), "WETH Vault", "vWETH");
        vm.prank(admin);
        erc4626Wrapper.addVault(address(wethVault));
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory data = abi.encodeWithSelector(ERC4626_DEPOSIT, address(wethVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    function test_E2E_ERC4626_Withdraw_ValidVault() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        _approveWrapper(walletAddr, address(yearnVault), address(erc4626Wrapper));
        bytes memory withdrawData = abi.encodeWithSelector(ERC4626_WITHDRAW, address(yearnVault), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, withdrawData);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_ERC4626_Withdraw_UnallowedVault_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        MockERC4626Vault unauthorizedVault = new MockERC4626Vault(address(usdc), "Bad Vault", "BAD");
        bytes memory data = abi.encodeWithSelector(ERC4626_WITHDRAW, address(unauthorizedVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    function test_E2E_ERC4626_DepositWithdrawCycle() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6);
        _approveWrapper(walletAddr, address(yearnVault), address(erc4626Wrapper));
        bytes memory withdrawData = abi.encodeWithSelector(ERC4626_WITHDRAW, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, withdrawData);
        assertEq(usdc.balanceOf(walletAddr), 1000e6);
        assertEq(yearnVault.balanceOf(walletAddr), 0);
    }

    // ============ Aave V3 Wrapper Tests ============

    function test_E2E_AaveV3_Deposit_ValidAsset() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        bytes memory data = abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, data);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(aUsdc.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_AaveV3_Deposit_UnallowedAsset_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        weth.mint(walletAddr, 1000e18);
        _approveWrapper(walletAddr, address(weth), address(aaveWrapper));
        bytes memory data = abi.encodeWithSelector(AAVE_DEPOSIT, address(weth), 500e18);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(aaveWrapper), 0, data);
    }

    function test_E2E_AaveV3_Deposit_AssetMismatch_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        MockAToken aWeth = new MockAToken(address(weth), "Aave WETH", "aWETH");
        aWeth.setPool(address(aavePool));
        aavePool.setAToken(address(weth), address(aWeth));
        vm.prank(admin);
        aaveWrapper.addAsset(address(weth), address(aWeth));
        weth.mint(walletAddr, 1000e18);
        _approveWrapper(walletAddr, address(weth), address(aaveWrapper));
        bytes memory data = abi.encodeWithSelector(AAVE_DEPOSIT, address(weth), 500e18);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(aaveWrapper), 0, data);
    }

    function test_E2E_AaveV3_Withdraw_ValidAsset() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        bytes memory depositData = abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, depositData);
        _approveWrapper(walletAddr, address(aUsdc), address(aaveWrapper));
        bytes memory withdrawData = abi.encodeWithSelector(AAVE_WITHDRAW, address(usdc), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, withdrawData);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(aUsdc.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_AaveV3_Withdraw_UnallowedAsset_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        bytes memory data = abi.encodeWithSelector(AAVE_WITHDRAW, address(weth), 500e18);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(aaveWrapper), 0, data);
    }

    function test_E2E_AaveV3_DepositWithdrawCycle() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        bytes memory depositData = abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, depositData);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(aUsdc.balanceOf(walletAddr), 1000e6);
        _approveWrapper(walletAddr, address(aUsdc), address(aaveWrapper));
        bytes memory withdrawData = abi.encodeWithSelector(AAVE_WITHDRAW, address(usdc), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, withdrawData);
        assertEq(usdc.balanceOf(walletAddr), 1000e6);
        assertEq(aUsdc.balanceOf(walletAddr), 0);
    }

    // ============ Merkl Validator Tests ============

    function test_E2E_MerklClaim_ForSelf_Allowed() public {
        address walletAddr = _createWallet(user1, 0);
        address[] memory users = new address[](1);
        users[0] = walletAddr;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        bytes memory data = abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs);
        vm.prank(operator);
        router.executeAction(walletAddr, address(merklDistributor), 0, data);
        assertEq(rewardToken.balanceOf(walletAddr), 100e18);
    }

    function test_E2E_MerklClaim_ForOtherAddress_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        address[] memory users = new address[](1);
        users[0] = randomUser;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        bytes memory data = abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(merklDistributor), 0, data);
    }

    function test_E2E_MerklClaim_EmptyUsers_Allowed() public {
        address walletAddr = _createWallet(user1, 0);
        address[] memory users = new address[](0);
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);
        bytes memory data = abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs);
        // Empty claims are allowed by the validator (no users to check)
        // The actual call to Merkl would be a no-op
        vm.prank(operator);
        router.executeAction(walletAddr, address(merklDistributor), 0, data);
    }

    function test_E2E_MerklClaim_MultipleUsers_OnlyWalletIncluded_Allowed() public {
        address walletAddr = _createWallet(user1, 0);
        address[] memory users = new address[](2);
        users[0] = walletAddr;
        users[1] = walletAddr;
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken);
        tokens[1] = address(usdc);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e6;
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        bytes memory data = abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs);
        vm.prank(operator);
        router.executeAction(walletAddr, address(merklDistributor), 0, data);
        assertEq(rewardToken.balanceOf(walletAddr), 100e18);
        assertEq(usdc.balanceOf(walletAddr), 50e6);
    }

    // ============ ZeroEx Validator Tests ============

    function test_E2E_ZeroExSwap_OutputMatchesBaseAsset_Allowed() public {
        address walletAddr = _createWallet(user1, 0);
        rewardToken.mint(walletAddr, 100e18);
        _approveWrapper(walletAddr, address(rewardToken), address(zeroExRouter));
        bytes[] memory transformations = new bytes[](0);
        bytes memory data = abi.encodeWithSelector(ZEROEX_TRANSFORM, address(rewardToken), address(usdc), 100e18, 90e6, transformations);
        vm.prank(operator);
        router.executeAction(walletAddr, address(zeroExRouter), 0, data);
        assertEq(rewardToken.balanceOf(walletAddr), 0);
        assertEq(usdc.balanceOf(walletAddr), 90e6);
    }

    function test_E2E_ZeroExSwap_OutputNotBaseAsset_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 100e6);
        _approveWrapper(walletAddr, address(usdc), address(zeroExRouter));
        bytes[] memory transformations = new bytes[](0);
        bytes memory data = abi.encodeWithSelector(ZEROEX_TRANSFORM, address(usdc), address(weth), 100e6, 1e18, transformations);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(zeroExRouter), 0, data);
    }

    function test_E2E_ZeroExSwap_WrongSelector_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 100e6);
        bytes4 wrongSelector = bytes4(keccak256("swap(address,address,uint256)"));
        bytes memory data = abi.encodeWithSelector(wrongSelector, address(usdc), address(weth), 100e6);
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, address(zeroExRouter), 0, data);
    }

    // ============ Cross-Adapter Flows ============

    function test_E2E_DepositToMultipleVaults_ERC4626AndAave() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 3000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        vm.startPrank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6));
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(morphoVault), 1000e6));
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 1000e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6);
        assertEq(morphoVault.balanceOf(walletAddr), 1000e6);
        assertEq(aUsdc.balanceOf(walletAddr), 1000e6);
    }

    function test_E2E_WithdrawFromMultipleVaults_ERC4626AndAave() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 3000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        vm.startPrank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6));
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(morphoVault), 1000e6));
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 1000e6));
        vm.stopPrank();
        _approveWrapper(walletAddr, address(yearnVault), address(erc4626Wrapper));
        _approveWrapper(walletAddr, address(morphoVault), address(erc4626Wrapper));
        _approveWrapper(walletAddr, address(aUsdc), address(aaveWrapper));
        vm.startPrank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_WITHDRAW, address(yearnVault), 1000e6));
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_WITHDRAW, address(morphoVault), 1000e6));
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(AAVE_WITHDRAW, address(usdc), 1000e6));
        vm.stopPrank();
        assertEq(usdc.balanceOf(walletAddr), 3000e6);
        assertEq(yearnVault.balanceOf(walletAddr), 0);
        assertEq(morphoVault.balanceOf(walletAddr), 0);
        assertEq(aUsdc.balanceOf(walletAddr), 0);
    }

    function test_E2E_MigrateFromAaveToERC4626() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(aaveWrapper));
        bytes memory depositData = abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, depositData);
        assertEq(aUsdc.balanceOf(walletAddr), 1000e6);
        _approveWrapper(walletAddr, address(aUsdc), address(aaveWrapper));
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        vm.startPrank(operator);
        router.executeAction(walletAddr, address(aaveWrapper), 0, abi.encodeWithSelector(AAVE_WITHDRAW, address(usdc), 1000e6));
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6));
        vm.stopPrank();
        assertEq(aUsdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6);
    }

    // ============ Batch Operations ============

    function test_E2E_BatchDepositMultipleVaults() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 2000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution({target: address(erc4626Wrapper), value: 0, callData: abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6)});
        executions[1] = Execution({target: address(erc4626Wrapper), value: 0, callData: abi.encodeWithSelector(ERC4626_DEPOSIT, address(morphoVault), 1000e6)});
        vm.prank(operator);
        router.executeActions(walletAddr, executions);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6);
        assertEq(morphoVault.balanceOf(walletAddr), 1000e6);
    }

    function test_E2E_BatchWithdrawAndSwap() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        rewardToken.mint(walletAddr, 50e18);
        _approveWrapper(walletAddr, address(yearnVault), address(erc4626Wrapper));
        _approveWrapper(walletAddr, address(rewardToken), address(zeroExRouter));
        bytes[] memory transformations = new bytes[](0);
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution({target: address(erc4626Wrapper), value: 0, callData: abi.encodeWithSelector(ERC4626_WITHDRAW, address(yearnVault), 500e6)});
        executions[1] = Execution({target: address(zeroExRouter), value: 0, callData: abi.encodeWithSelector(ZEROEX_TRANSFORM, address(rewardToken), address(usdc), 50e18, 45e6, transformations)});
        vm.prank(operator);
        router.executeActions(walletAddr, executions);
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
        assertEq(rewardToken.balanceOf(walletAddr), 0);
        assertEq(usdc.balanceOf(walletAddr), 545e6);
    }

    function test_E2E_BatchClaimSwapDeposit() public {
        address walletAddr = _createWallet(user1, 0);
        _approveWrapper(walletAddr, address(rewardToken), address(zeroExRouter));
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        address[] memory users = new address[](1);
        users[0] = walletAddr;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        bytes[] memory transformations = new bytes[](0);
        Execution[] memory executions = new Execution[](3);
        executions[0] = Execution({target: address(merklDistributor), value: 0, callData: abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs)});
        executions[1] = Execution({target: address(zeroExRouter), value: 0, callData: abi.encodeWithSelector(ZEROEX_TRANSFORM, address(rewardToken), address(usdc), 100e18, 90e6, transformations)});
        executions[2] = Execution({target: address(erc4626Wrapper), value: 0, callData: abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 90e6)});
        vm.prank(operator);
        router.executeActions(walletAddr, executions);
        assertEq(rewardToken.balanceOf(walletAddr), 0);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 90e6);
    }

    // ============ ERC-4337 UserOp Flows ============

    function test_E2E_UserOp_V08_DepositToVault() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(erc4626Wrapper), 0, depositData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        PackedUserOperation memory userOp = PackedUserOperation({sender: walletAddr, nonce: 0, initCode: "", callData: callData, accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0), paymasterAndData: "", signature: ""});
        bytes32 userOpHash = entryPointV08().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        entryPointV08().handleOps(ops, payable(admin));
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_UserOp_V06_DepositToVault() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(erc4626Wrapper), 0, depositData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        IEntryPointV06.UserOperation memory userOp = IEntryPointV06.UserOperation({sender: walletAddr, nonce: 0, initCode: "", callData: callData, callGasLimit: 1000000, verificationGasLimit: 1000000, preVerificationGas: 100000, maxFeePerGas: 1 gwei, maxPriorityFeePerGas: 1 gwei, paymasterAndData: "", signature: ""});
        bytes32 userOpHash = entryPointV06().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        IEntryPointV06.UserOperation[] memory ops = new IEntryPointV06.UserOperation[](1);
        ops[0] = userOp;
        entryPointV06().handleOps(ops, payable(admin));
        assertEq(yearnVault.balanceOf(walletAddr), 500e6);
    }

    function test_E2E_UserOp_InvalidSignature_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(erc4626Wrapper), 0, depositData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        PackedUserOperation memory userOp = PackedUserOperation({sender: walletAddr, nonce: 0, initCode: "", callData: callData, accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0), paymasterAndData: "", signature: ""});
        uint256 wrongPrivateKey = 0x999;
        bytes32 userOpHash = entryPointV08().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert("Invalid UserOp");
        entryPointV08().handleOps(ops, payable(admin));
    }

    // ============ Access Control Tests ============

    function test_E2E_NonOperator_CannotExecute() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        bytes memory data = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(randomUser);
        vm.expectRevert("Router: not authorized");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    function test_E2E_RemovedOperator_CannotExecute() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        vm.prank(admin);
        router.removeOperator(operator);
        bytes memory data = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Router: not authorized");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    function test_E2E_UnauthorizedTarget_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        address randomTarget = address(0x999);
        bytes memory data = abi.encodeWithSelector(bytes4(keccak256("foo()")));
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, randomTarget, 0, data);
    }

    function test_E2E_UnauthorizedSelector_Blocked() public {
        address walletAddr = _createWallet(user1, 0);
        bytes4 unauthorizedSelector = bytes4(keccak256("unauthorizedMethod()"));
        bytes memory data = abi.encodeWithSelector(unauthorizedSelector);
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data);
    }

    // ============ User Sovereignty Tests ============

    function test_E2E_UserCanWithdrawAnytime() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        vm.prank(admin);
        router.removeOperator(operator);
        vm.prank(user1);
        YieldSeekerAgentWallet(payable(walletAddr)).withdrawTokenToUser(address(yearnVault), user1, 1000e6);
        assertEq(yearnVault.balanceOf(user1), 1000e6);
    }

    function test_E2E_UserCanUpgradeWallet() public {
        address walletAddr = _createWallet(user1, 0);
        YieldSeekerAgentWallet newImpl = new YieldSeekerAgentWallet();
        vm.prank(user1);
        YieldSeekerAgentWallet(payable(walletAddr)).upgradeToAndCall(address(newImpl), "");
    }

    function test_E2E_OperatorCannotWithdrawToSelf() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        bytes memory data = abi.encodeCall(IERC20.transfer, (operator, 1000e6));
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, address(usdc), 0, data);
    }

    // ============ Emergency Scenarios ============

    function test_E2E_EmergencyRemoveOperator_BlocksExecution() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        vm.prank(admin);
        router.removeOperator(operator);
        bytes memory data2 = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Router: not authorized");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data2);
    }

    function test_E2E_EmergencyRemovePolicy_BlocksAction() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        vm.prank(admin);
        policy.removePolicy(address(erc4626Wrapper), ERC4626_DEPOSIT);
        bytes memory data2 = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data2);
    }

    function test_E2E_EmergencyRemoveVault_BlocksDeposit() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        vm.prank(admin);
        erc4626Wrapper.removeVault(address(yearnVault));
        bytes memory data2 = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 500e6);
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, data2);
    }

    // ============ Full Yield Cycle ============

    function test_E2E_FullYieldCycle_ClaimSwapDeposit() public {
        address walletAddr = _createWallet(user1, 0);
        _fundWallet(walletAddr, 1000e6);
        _approveWrapper(walletAddr, address(usdc), address(erc4626Wrapper));
        bytes memory depositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, depositData);
        assertEq(yearnVault.balanceOf(walletAddr), 1000e6);
        address[] memory users = new address[](1);
        users[0] = walletAddr;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50e18;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        bytes memory claimData = abi.encodeWithSelector(MERKL_CLAIM, users, tokens, amounts, proofs);
        vm.prank(operator);
        router.executeAction(walletAddr, address(merklDistributor), 0, claimData);
        assertEq(rewardToken.balanceOf(walletAddr), 50e18);
        _approveWrapper(walletAddr, address(rewardToken), address(zeroExRouter));
        bytes[] memory transformations = new bytes[](0);
        bytes memory swapData = abi.encodeWithSelector(ZEROEX_TRANSFORM, address(rewardToken), address(usdc), 50e18, 45e6, transformations);
        vm.prank(operator);
        router.executeAction(walletAddr, address(zeroExRouter), 0, swapData);
        assertEq(rewardToken.balanceOf(walletAddr), 0);
        assertEq(usdc.balanceOf(walletAddr), 45e6);
        bytes memory reDepositData = abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 45e6);
        vm.prank(operator);
        router.executeAction(walletAddr, address(erc4626Wrapper), 0, reDepositData);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(yearnVault.balanceOf(walletAddr), 1045e6);
    }

    function test_E2E_MultiAgentOrchestration() public {
        address wallet1 = _createWallet(user1, 0);
        address wallet2 = _createWallet(user2, 0);
        _fundWallet(wallet1, 1000e6);
        _fundWallet(wallet2, 2000e6);
        _approveWrapper(wallet1, address(usdc), address(erc4626Wrapper));
        _approveWrapper(wallet2, address(usdc), address(aaveWrapper));
        vm.startPrank(operator);
        router.executeAction(wallet1, address(erc4626Wrapper), 0, abi.encodeWithSelector(ERC4626_DEPOSIT, address(yearnVault), 1000e6));
        router.executeAction(wallet2, address(aaveWrapper), 0, abi.encodeWithSelector(AAVE_DEPOSIT, address(usdc), 2000e6));
        vm.stopPrank();
        assertEq(yearnVault.balanceOf(wallet1), 1000e6);
        assertEq(aUsdc.balanceOf(wallet2), 2000e6);
        assertEq(YieldSeekerAgentWallet(payable(wallet1)).user(), user1);
        assertEq(YieldSeekerAgentWallet(payable(wallet2)).user(), user2);
    }
}
