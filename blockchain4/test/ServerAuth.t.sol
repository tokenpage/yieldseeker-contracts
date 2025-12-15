// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/AgentWallet.sol";
import "../src/AgentWalletFactory.sol";
import "../src/ActionRegistry.sol";
import "../src/erc4337/UserOperation.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ServerAuthTest
 * @notice Tests for yieldSeekerServer authorization in AgentWallet
 */
contract ServerAuthTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    AgentWalletFactory public factory;
    ActionRegistry public registry;
    AgentWallet public wallet;

    address public admin;
    address public user;
    uint256 public userPrivateKey;
    address public server;
    uint256 public serverPrivateKey;
    address public entryPoint = address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);

    function setUp() public {
        admin = address(this);

        // Generate user keypair
        userPrivateKey = 0x1234;
        user = vm.addr(userPrivateKey);

        // Generate server keypair
        serverPrivateKey = 0x5678;
        server = vm.addr(serverPrivateKey);

        // Deploy contracts
        registry = new ActionRegistry(admin);
        factory = new AgentWalletFactory(admin);

        // Deploy implementation
        AgentWallet impl = new AgentWallet(IEntryPoint(entryPoint), address(factory));

        // Configure factory
        factory.setRegistry(registry);
        factory.setImplementation(impl);

        // Create wallet
        AgentWallet walletContract = factory.createAccount(user, 0);
        wallet = AgentWallet(payable(address(walletContract)));
    }

    function test_ServerAuth_NoServerSet_OnlyOwnerAccepted() public view {
        // When no server is set, only owner signature should be valid
        bytes32 hash = keccak256("test message");
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, ethSignedHash);
        bytes memory ownerSig = abi.encodePacked(r, s, v);

        address recovered = ethSignedHash.recover(ownerSig);
        assertEq(recovered, user, "Owner signature should recover to user");

        // Verify server is not set
        assertEq(registry.yieldSeekerServer(), address(0), "Server should not be set initially");
    }

    function test_ServerAuth_SetServer_Success() public {
        // Admin sets the server
        registry.setYieldSeekerServer(server);

        assertEq(registry.yieldSeekerServer(), server, "Server should be set");
    }

    function test_ServerAuth_SetServer_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.YieldSeekerServerUpdated(address(0), server);

        registry.setYieldSeekerServer(server);
    }

    function test_ServerAuth_SetServer_OnlyAdmin() public {
        address randomUser = address(0x999);

        vm.prank(randomUser);
        vm.expectRevert();
        registry.setYieldSeekerServer(server);
    }

    function test_ServerAuth_ValidServerSignature_Accepted() public {
        // Set server
        registry.setYieldSeekerServer(server);

        // Create a UserOp hash
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        // Sign with server key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(serverPrivateKey, ethSignedHash);
        bytes memory serverSig = abi.encodePacked(r, s, v);

        // Verify signature recovers to server
        address recovered = ethSignedHash.recover(serverSig);
        assertEq(recovered, server, "Server signature should recover to server address");
    }

    function test_ServerAuth_InvalidServerSignature_Rejected() public {
        // Set server
        registry.setYieldSeekerServer(server);

        // Create a UserOp hash
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        // Sign with random key
        uint256 randomKey = 0x9999;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomKey, ethSignedHash);
        bytes memory randomSig = abi.encodePacked(r, s, v);

        // Verify signature does NOT recover to server or owner
        address recovered = ethSignedHash.recover(randomSig);
        assertTrue(recovered != server && recovered != user, "Random signature should not match server or owner");
    }

    function test_ServerAuth_ServerRotation_OldServerRejected() public {
        // Set initial server
        registry.setYieldSeekerServer(server);

        // Generate new server
        uint256 newServerPrivateKey = 0xABCD;
        address newServer = vm.addr(newServerPrivateKey);

        // Rotate to new server
        registry.setYieldSeekerServer(newServer);

        assertEq(registry.yieldSeekerServer(), newServer, "New server should be set");

        // Old server signature should not be valid anymore
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(serverPrivateKey, ethSignedHash);
        bytes memory oldServerSig = abi.encodePacked(r, s, v);

        address recovered = ethSignedHash.recover(oldServerSig);
        assertEq(recovered, server, "Old server sig still recovers to old server");
        assertTrue(recovered != newServer, "Old server sig should not match new server");
    }

    function test_ServerAuth_ServerRevocation_ServerDisabled() public {
        // Set server
        registry.setYieldSeekerServer(server);
        assertEq(registry.yieldSeekerServer(), server);

        // Revoke server by setting to address(0)
        registry.setYieldSeekerServer(address(0));

        assertEq(registry.yieldSeekerServer(), address(0), "Server should be revoked");
    }

    function test_ServerAuth_OwnerSignatureAlwaysValid() public {
        // Set server
        registry.setYieldSeekerServer(server);

        // Owner signature should still be valid
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, ethSignedHash);
        bytes memory ownerSig = abi.encodePacked(r, s, v);

        address recovered = ethSignedHash.recover(ownerSig);
        assertEq(recovered, user, "Owner signature should still be valid when server is set");
    }

    function test_ServerAuth_BothOwnerAndServerValid() public {
        // Set server
        registry.setYieldSeekerServer(server);

        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        // Owner signature
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(userPrivateKey, ethSignedHash);
        bytes memory ownerSig = abi.encodePacked(r1, s1, v1);
        address ownerRecovered = ethSignedHash.recover(ownerSig);

        // Server signature
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(serverPrivateKey, ethSignedHash);
        bytes memory serverSig = abi.encodePacked(r2, s2, v2);
        address serverRecovered = ethSignedHash.recover(serverSig);

        assertEq(ownerRecovered, user, "Owner signature should be valid");
        assertEq(serverRecovered, server, "Server signature should be valid");
        assertTrue(ownerRecovered != serverRecovered, "Owner and server should be different addresses");
    }
}
