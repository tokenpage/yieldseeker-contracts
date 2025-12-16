// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerActionRegistry as ActionRegistry} from "../src/ActionRegistry.sol";
import {YieldSeekerAdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {IEntryPoint} from "../src/erc4337/IEntryPoint.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ServerAuthTest
 * @notice Tests for yieldSeekerServer authorization in AgentWallet
 */
contract ServerAuthTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    YieldSeekerAdminTimelock public timelock;
    YieldSeekerAgentWalletFactory public factory;
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

        // Deploy AdminTimelock
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        timelock = new YieldSeekerAdminTimelock(0, proposers, executors, address(0));

        // Deploy contracts with timelock as admin
        registry = new ActionRegistry(address(timelock), admin);
        factory = new YieldSeekerAgentWalletFactory(address(timelock), admin);

        // Deploy implementation
        AgentWallet impl = new AgentWallet(IEntryPoint(entryPoint), address(factory));

        // Configure factory (via timelock)
        bytes memory setRegistryData = abi.encodeWithSelector(factory.setRegistry.selector, registry);
        bytes32 salt1 = bytes32(uint256(1));
        timelock.schedule(address(factory), 0, setRegistryData, bytes32(0), salt1, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(factory), 0, setRegistryData, bytes32(0), salt1);

        bytes memory setImplData = abi.encodeWithSelector(factory.setImplementation.selector, impl);
        bytes32 salt2 = bytes32(uint256(2));
        vm.warp(block.timestamp + 1); // Move time forward slightly to avoid timestamp collision
        timelock.schedule(address(factory), 0, setImplData, bytes32(0), salt2, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(factory), 0, setImplData, bytes32(0), salt2);

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
        // Admin sets the server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(100)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(100)));

        assertEq(registry.yieldSeekerServer(), server, "Server should be set");
    }

    function test_ServerAuth_SetServer_EmitsEvent() public {
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(101)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.YieldSeekerServerUpdated(address(0), server);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(101)));
    }

    function test_ServerAuth_SetServer_OnlyAdmin() public {
        address randomUser = address(0x999);

        // Random user cannot schedule timelock operations
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        vm.prank(randomUser);
        vm.expectRevert();
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(110)), 24 hours);
    }

    function test_ServerAuth_ValidServerSignature_Accepted() public {
        // Set server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(102)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(102)));

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
        // Set server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(103)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(103)));

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
        // Set initial server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        bytes32 salt1 = bytes32(uint256(104));
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), salt1, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), salt1);

        // Generate new server
        uint256 newServerPrivateKey = 0xABCD;
        address newServer = vm.addr(newServerPrivateKey);

        // Rotate to new server via timelock (advance time to avoid operation collision)
        vm.warp(block.timestamp + 1);
        bytes memory setNewServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, newServer);
        bytes32 salt2 = bytes32(uint256(105));
        timelock.schedule(address(registry), 0, setNewServerData, bytes32(0), salt2, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setNewServerData, bytes32(0), salt2);

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
        // Set server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(106)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(106)));
        assertEq(registry.yieldSeekerServer(), server);

        // Revoke server by setting to address(0) via timelock
        bytes memory revokeServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, address(0));
        timelock.schedule(address(registry), 0, revokeServerData, bytes32(0), bytes32(uint256(107)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, revokeServerData, bytes32(0), bytes32(uint256(107)));

        assertEq(registry.yieldSeekerServer(), address(0), "Server should be revoked");
    }

    function test_ServerAuth_OwnerSignatureAlwaysValid() public {
        // Set server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(108)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(108)));

        // Owner signature should still be valid
        bytes32 userOpHash = keccak256("userOp");
        bytes32 ethSignedHash = userOpHash.toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, ethSignedHash);
        bytes memory ownerSig = abi.encodePacked(r, s, v);

        address recovered = ethSignedHash.recover(ownerSig);
        assertEq(recovered, user, "Owner signature should still be valid when server is set");
    }

    function test_ServerAuth_BothOwnerAndServerValid() public {
        // Set server via timelock
        bytes memory setServerData = abi.encodeWithSelector(registry.setYieldSeekerServer.selector, server);
        timelock.schedule(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(109)), 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(address(registry), 0, setServerData, bytes32(0), bytes32(uint256(109)));

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
