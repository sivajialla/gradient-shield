// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title DemoSimulationTest
/// @notice End-to-end demo showing how GradientShield treats four different
///         address types through the full lifecycle:
///
///   1. CLEAN_TRADER   - never flagged, always pays base fee
///   2. OCCASIONAL_MEV - scored once (40), decays back to clean over time
///   3. SANDWICH_BOT   - repeatedly scored, escalates to rejection
///   4. REFORMED_BOT   - scored high (85), stops, decays to clean
///
///   Each scenario uses the ServiceManager's full task->sign->respond->oracle
///   flow, then checks the score against GradientShieldHook's thresholds
///   to show the fee/reject outcome.
contract DemoSimulationTest is Test {
    ScoringOracle internal oracle;
    GradientShieldServiceManager internal sm;

    // Operator key pair (Foundry cheatcode)
    uint256 internal operatorPk = 0xA11CE;
    address internal operatorAddr;

    // The four characters in our demo
    address internal constant CLEAN_TRADER = address(0x1111);
    address internal constant OCCASIONAL_MEV = address(0x2222);
    address internal constant SANDWICH_BOT = address(0x3333);
    address internal constant REFORMED_BOT = address(0x4444);

    // Hook thresholds (mirrored from GradientShieldHook)
    uint16 internal constant SUSPICIOUS_THRESHOLD = 40;
    uint16 internal constant REJECT_THRESHOLD = 80;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant ESCALATION_MULTIPLIER = 3;

    function setUp() public {
        operatorAddr = vm.addr(operatorPk);

        // Deploy the stack
        oracle = new ScoringOracle(address(0));
        sm = new GradientShieldServiceManager(oracle);
        oracle.setAvs(address(sm));

        // Register the operator
        vm.prank(operatorAddr);
        sm.registerOperator(operatorAddr);
    }

    // =================================================================
    //  DEMO 1: Clean trader - never flagged
    // =================================================================

    function test_demo_cleanTrader() public {
        console2.log("");
        console2.log("=== DEMO 1: Clean Trader (0x1111) ===");

        uint16 score = oracle.getScore(CLEAN_TRADER);
        (string memory band, uint24 fee) = _feeDecision(score);

        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Swap passes at base fee");

        assertEq(score, 0);
        assertEq(fee, BASE_FEE);
    }

    // =================================================================
    //  DEMO 2: Occasional MEV - scored 40, decays back to clean
    // =================================================================

    function test_demo_occasionalMEV() public {
        console2.log("");
        console2.log("=== DEMO 2: Occasional MEV Extractor (0x2222) ===");

        // --- Day 0: AVS detects one suspicious swap pattern ---
        console2.log("");
        console2.log("  Day 0: AVS detects suspicious activity");
        _operatorScores(OCCASIONAL_MEV, 100, 200, 40);

        uint16 score = oracle.getScore(OCCASIONAL_MEV);
        (string memory band, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 40);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        // --- Day 4: No more bad behavior, score decays ---
        console2.log("");
        console2.log("  Day 4: No further bad activity, score decaying...");
        vm.warp(block.timestamp + 4 days);

        score = oracle.getScore(OCCASIONAL_MEV);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score); // 40 - (4 * 5) = 20
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 20);
        assertEq(fee, BASE_FEE); // back to base fee

        // --- Day 8: Fully decayed ---
        console2.log("");
        console2.log("  Day 8: Fully decayed, address forgiven");
        vm.warp(block.timestamp + 4 days);

        score = oracle.getScore(OCCASIONAL_MEV);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score); // 0
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 0);
        assertEq(fee, BASE_FEE);
    }

    // =================================================================
    //  DEMO 3: Sandwich bot - escalates to rejection
    // =================================================================

    function test_demo_sandwichBot() public {
        console2.log("");
        console2.log("=== DEMO 3: Persistent Sandwich Bot (0x3333) ===");

        // --- Round 1: First detection, scored 55 ---
        console2.log("");
        console2.log("  Round 1: First sandwich detected");
        _operatorScores(SANDWICH_BOT, 100, 200, 55);

        uint16 score = oracle.getScore(SANDWICH_BOT);
        (string memory band, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Swap allowed but at 3x fee");
        assertEq(score, 55);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        // --- Round 2 (next day): Bot keeps going, bumped by 25 ---
        console2.log("");
        console2.log("  Round 2 (1 day later): Bot keeps sandwiching");
        vm.warp(block.timestamp + 1 days);
        // Decayed: 55 - 5 = 50. Bump by 25 -> 75
        _operatorBumps(SANDWICH_BOT, 200, 300, 25);

        score = oracle.getScore(SANDWICH_BOT);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Still allowed at 3x, getting close to rejection");
        assertEq(score, 75);

        // --- Round 3 (same day): Still at it, bumped by 20 ---
        console2.log("");
        console2.log("  Round 3 (same day): Bot STILL at it");
        _operatorBumps(SANDWICH_BOT, 300, 400, 20);

        score = oracle.getScore(SANDWICH_BOT);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score); // 75 + 20 = 95
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    REJECTED - swap would revert with BotRejected");
        assertEq(score, 95);
        assertTrue(score >= REJECT_THRESHOLD);
    }

    // =================================================================
    //  DEMO 4: Reformed bot - scored high, stops, heals
    // =================================================================

    function test_demo_reformedBot() public {
        console2.log("");
        console2.log("=== DEMO 4: Reformed Bot (0x4444) ===");

        // --- Day 0: Caught badly, scored 85 (rejected) ---
        console2.log("");
        console2.log("  Day 0: Caught in an aggressive sandwich, scored 85");
        _operatorScores(REFORMED_BOT, 100, 200, 85);

        uint16 score = oracle.getScore(REFORMED_BOT);
        (, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Status:    REJECTED (score >= 80)");
        assertTrue(score >= REJECT_THRESHOLD);

        // --- Day 1: Still rejected ---
        console2.log("");
        console2.log("  Day 1: Bot stops. Score decays to 80 - still rejected");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        console2.log("  Score:    ", score);
        assertEq(score, 80);
        assertTrue(score >= REJECT_THRESHOLD);

        // --- Day 2: Drops to suspicious band ---
        console2.log("");
        console2.log("  Day 2: Score decays to 75 - now allowed at 3x fee");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        (, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 75);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        // --- Day 9: Drops below suspicious ---
        console2.log("");
        console2.log("  Day 9: Score decays to 40 - border of suspicious");
        vm.warp(block.timestamp + 7 days);
        score = oracle.getScore(REFORMED_BOT);
        (, fee) = _feeDecision(score);
        console2.log("  Score:    ", score); // 85 - (9 * 5) = 40
        assertEq(score, 40);

        // --- Day 10: Clean ---
        console2.log("");
        console2.log("  Day 10: Score 35 - back to base fee, address rehabilitated");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        (, fee) = _feeDecision(score);
        console2.log("  Score:    ", score); // 85 - (10 * 5) = 35
        console2.log("  Fee (pips):", fee);
        assertEq(score, 35);
        assertEq(fee, BASE_FEE);

        // --- Day 17: Fully decayed ---
        console2.log("");
        console2.log("  Day 17: Score 0 - fully clean, indistinguishable from honest trader");
        vm.warp(block.timestamp + 7 days);
        score = oracle.getScore(REFORMED_BOT);
        console2.log("  Score:    ", score);
        assertEq(score, 0);
    }

    // =================================================================
    //  DEMO 5: Side-by-side comparison at a single point in time
    // =================================================================

    function test_demo_sideBySide() public {
        console2.log("");
        console2.log("=== DEMO 5: Side-by-Side - Same Pool, Same Block ===");
        console2.log("");

        // Set up scores for each address
        _operatorScores(OCCASIONAL_MEV, 100, 200, 35); // just under suspicious
        _operatorScores(SANDWICH_BOT, 100, 200, 60);   // suspicious
        _operatorScores(REFORMED_BOT, 100, 200, 90);    // toxic

        console2.log("  Four addresses swap in the same block:");
        console2.log("  -----------------------------------------------");

        address[4] memory addrs = [CLEAN_TRADER, OCCASIONAL_MEV, SANDWICH_BOT, REFORMED_BOT];
        string[4] memory names = ["Clean Trader  ", "Occasional MEV", "Sandwich Bot  ", "Reformed Bot  "];

        for (uint256 i = 0; i < 4; i++) {
            uint16 score = oracle.getScore(addrs[i]);
            (string memory band, uint24 fee) = _feeDecision(score);
            console2.log("");
            console2.log("  ", names[i]);
            console2.log("    Score:", score);
            console2.log("    Band: ", band);
            if (score >= REJECT_THRESHOLD) {
                console2.log("    --->   SWAP REJECTED");
            } else {
                console2.log("    Fee:  ", fee, "pips");
            }
        }
    }

    // =================================================================
    //  Internal helpers
    // =================================================================

    /// @dev Full task->sign->respond flow for an absolute setScore
    function _operatorScores(address subject, uint32 fromBlock, uint32 toBlock, uint16 score) internal {
        uint32 taskId = sm.createScoreTask(subject, fromBlock, toBlock);

        bytes32 messageHash = keccak256(abi.encodePacked(taskId, subject, score));
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSignedHash);

        vm.prank(operatorAddr);
        sm.respondToTask(taskId, score, abi.encodePacked(r, s, v));
    }

    /// @dev Bump via the oracle directly (the ServiceManager only has setScore;
    ///      bumpScore would need its own task type - simplified for demo)
    function _operatorBumps(address subject, uint32 fromBlock, uint32 toBlock, uint16 delta) internal {
        // Read current decayed score + compute new
        uint16 current = oracle.getScore(subject);
        uint16 newScore = current + delta;
        if (newScore > 100) newScore = 100;

        // Go through the full ServiceManager flow with the computed score
        _operatorScores(subject, fromBlock, toBlock, newScore);
    }

    function _feeDecision(uint16 score) internal pure returns (string memory band, uint24 fee) {
        if (score >= REJECT_THRESHOLD) {
            return ("REJECTED", 0);
        } else if (score >= SUSPICIOUS_THRESHOLD) {
            return ("SUSPICIOUS", BASE_FEE * ESCALATION_MULTIPLIER);
        } else {
            return ("CLEAN", BASE_FEE);
        }
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
