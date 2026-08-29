// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title ServiceManagerTest
/// @notice Tests the ServiceManager: operator registration, task creation,
///         ECDSA-verified score responses, and oracle integration.
contract ServiceManagerTest is Test {
    GradientShieldServiceManager internal sm;
    ScoringOracle internal oracle;

    // Operator uses a Foundry cheatcode-derived key pair for signing
    uint256 internal operatorPk = 0xA11CE;
    address internal operatorAddr;
    address internal operatorSigningKey;

    address internal constant BOT = address(0xB07);

    function setUp() public {
        operatorAddr = vm.addr(operatorPk);
        operatorSigningKey = operatorAddr; // same key for simplicity

        oracle = new ScoringOracle(address(0)); // AVS not set yet
        sm = new GradientShieldServiceManager(oracle);

        // Point the oracle's AVS writer at the ServiceManager
        oracle.setAvs(address(sm));
    }

    // -----------------------------------------------------------------
    // Operator registration
    // -----------------------------------------------------------------

    function test_registerOperator() public {
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);

        (bool registered, address key) = sm.operators(operatorAddr);
        assertTrue(registered);
        assertEq(key, operatorSigningKey);
        assertEq(sm.operatorCount(), 1);
    }

    function test_cannotRegisterTwice() public {
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);

        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.AlreadyRegistered.selector);
        sm.registerOperator(operatorSigningKey);
    }

    function test_deregisterOperator() public {
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);

        vm.prank(operatorAddr);
        sm.deregisterOperator();

        (bool registered,) = sm.operators(operatorAddr);
        assertFalse(registered);
        assertEq(sm.operatorCount(), 0);
    }

    // -----------------------------------------------------------------
    // Task creation
    // -----------------------------------------------------------------

    function test_createTask() public {
        vm.expectEmit(true, true, false, true);
        emit GradientShieldServiceManager.ScoreTaskCreated(0, BOT, 100, 200);

        uint32 taskId = sm.createScoreTask(BOT, 100, 200);
        assertEq(taskId, 0);
        assertEq(sm.taskCount(), 1);

        GradientShieldServiceManager.ScoreTask memory task = sm.getTask(0);
        assertEq(task.subject, BOT);
        assertEq(task.fromBlock, 100);
        assertEq(task.toBlock, 200);
        assertFalse(task.responded);
    }

    function test_createTaskRejectsInvalidRange() public {
        vm.expectRevert(GradientShieldServiceManager.InvalidBlockRange.selector);
        sm.createScoreTask(BOT, 200, 100);
    }

    // -----------------------------------------------------------------
    // Task response (the core flow)
    // -----------------------------------------------------------------

    function test_respondToTask() public {
        // Setup: register operator + create task
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);
        uint32 taskId = sm.createScoreTask(BOT, 100, 200);

        // Operator signs (taskId, subject, score)
        uint16 score = 60;
        bytes32 messageHash = keccak256(abi.encodePacked(taskId, BOT, score));
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Submit as the operator
        vm.prank(operatorAddr);
        sm.respondToTask(taskId, score, signature);

        // Verify: task marked responded, oracle updated
        assertTrue(sm.getTask(taskId).responded);
        assertEq(oracle.getScore(BOT), 60);
    }

    function test_cannotRespondTwice() public {
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);
        uint32 taskId = sm.createScoreTask(BOT, 100, 200);

        bytes memory sig = _signResponse(taskId, BOT, 60);
        vm.prank(operatorAddr);
        sm.respondToTask(taskId, 60, sig);

        // Second response to same task reverts
        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.TaskAlreadyResponded.selector);
        sm.respondToTask(taskId, 60, sig);
    }

    function test_unregisteredOperatorRejected() public {
        sm.createScoreTask(BOT, 100, 200);

        bytes memory sig = _signResponse(0, BOT, 60);
        vm.prank(operatorAddr); // not registered
        vm.expectRevert(GradientShieldServiceManager.NotRegistered.selector);
        sm.respondToTask(0, 60, sig);
    }

    function test_wrongSignatureRejected() public {
        vm.prank(operatorAddr);
        sm.registerOperator(operatorSigningKey);
        sm.createScoreTask(BOT, 100, 200);

        // Sign with a different score than what's submitted
        bytes memory wrongSig = _signResponse(0, BOT, 99);
        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.InvalidSignature.selector);
        sm.respondToTask(0, 60, wrongSig); // submitting 60 but sig is for 99
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _signResponse(uint32 taskId, address subject, uint16 score) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(taskId, subject, score));
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
