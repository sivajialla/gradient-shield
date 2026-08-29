// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldTaskManager} from "../src/GradientShieldTaskManager.sol";
import {IGradientShieldTaskManager} from "../src/IGradientShieldTaskManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSSignatureChecker} from "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {BN254} from "eigenlayer-middleware/src/libraries/BN254.sol";

// Re-use the same test mocks from TaskManager.t.sol
import {MockPauserRegistry, TestableGradientShieldTaskManager} from "./TaskManager.t.sol";

contract DemoSimulationTest is Test {
    ScoringOracle internal oracle;
    TestableGradientShieldTaskManager internal tm;

    address internal aggregator = address(0xA66);
    address internal generator = address(0x6E11);
    address internal owner = address(0xDEAD);

    address internal constant CLEAN_TRADER = address(0x1111);
    address internal constant OCCASIONAL_MEV = address(0x2222);
    address internal constant SANDWICH_BOT = address(0x3333);
    address internal constant REFORMED_BOT = address(0x4444);

    uint16 internal constant SUSPICIOUS_THRESHOLD = 40;
    uint16 internal constant REJECT_THRESHOLD = 80;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant ESCALATION_MULTIPLIER = 3;

    function setUp() public {
        address mockRC = address(0xC0C0);
        address mockSR = address(0x5757);
        address mockAPK = address(0xA9A9);
        address mockDel = address(0xDE1E);

        vm.mockCall(mockRC, abi.encodeWithSignature("stakeRegistry()"), abi.encode(mockSR));
        vm.mockCall(mockRC, abi.encodeWithSignature("blsApkRegistry()"), abi.encode(mockAPK));
        vm.mockCall(mockSR, abi.encodeWithSignature("delegation()"), abi.encode(mockDel));

        IPauserRegistry pauserReg = new MockPauserRegistry();

        oracle = new ScoringOracle(address(0));

        TestableGradientShieldTaskManager impl = new TestableGradientShieldTaskManager(
            ISlashingRegistryCoordinator(mockRC), pauserReg, 100
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GradientShieldTaskManager.initialize, (owner, aggregator, generator, oracle))
        );
        tm = TestableGradientShieldTaskManager(address(proxy));
        oracle.setAvs(address(tm));
    }

    // =================================================================
    //  DEMO 1: Clean trader - never flagged
    // =================================================================

    function test_demo_cleanTrader() public view {
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

        console2.log("");
        console2.log("  Day 0: BLS quorum detects suspicious activity");
        _quorumScores(OCCASIONAL_MEV, 100, 200, 40);

        uint16 score = oracle.getScore(OCCASIONAL_MEV);
        (string memory band, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 40);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        console2.log("");
        console2.log("  Day 4: No further bad activity, score decaying...");
        vm.warp(block.timestamp + 4 days);

        score = oracle.getScore(OCCASIONAL_MEV);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 20);
        assertEq(fee, BASE_FEE);

        console2.log("");
        console2.log("  Day 8: Fully decayed, address forgiven");
        vm.warp(block.timestamp + 4 days);

        score = oracle.getScore(OCCASIONAL_MEV);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
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

        console2.log("");
        console2.log("  Round 1: First sandwich detected, BLS quorum agrees score=55");
        _quorumScores(SANDWICH_BOT, 100, 200, 55);

        uint16 score = oracle.getScore(SANDWICH_BOT);
        (string memory band, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Swap allowed but at 3x fee");
        assertEq(score, 55);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        console2.log("");
        console2.log("  Round 2 (1 day later): Bot keeps sandwiching, quorum bumps");
        vm.warp(block.timestamp + 1 days);
        _quorumBumps(SANDWICH_BOT, 200, 300, 25);

        score = oracle.getScore(SANDWICH_BOT);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Still allowed at 3x, getting close to rejection");
        assertEq(score, 75);

        console2.log("");
        console2.log("  Round 3 (same day): Bot STILL at it");
        _quorumBumps(SANDWICH_BOT, 300, 400, 20);

        score = oracle.getScore(SANDWICH_BOT);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
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

        console2.log("");
        console2.log("  Day 0: Caught in an aggressive sandwich, BLS quorum scores 85");
        _quorumScores(REFORMED_BOT, 100, 200, 85);

        uint16 score = oracle.getScore(REFORMED_BOT);
        console2.log("  Score:    ", score);
        console2.log("  Status:    REJECTED (score >= 80)");
        assertTrue(score >= REJECT_THRESHOLD);

        console2.log("");
        console2.log("  Day 1: Bot stops. Score decays to 80 - still rejected");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        console2.log("  Score:    ", score);
        assertEq(score, 80);
        assertTrue(score >= REJECT_THRESHOLD);

        console2.log("");
        console2.log("  Day 2: Score decays to 75 - now allowed at 3x fee");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        (, uint24 fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 75);
        assertEq(fee, BASE_FEE * ESCALATION_MULTIPLIER);

        console2.log("");
        console2.log("  Day 9: Score decays to 40 - border of suspicious");
        vm.warp(block.timestamp + 7 days);
        score = oracle.getScore(REFORMED_BOT);
        assertEq(score, 40);

        console2.log("");
        console2.log("  Day 10: Score 35 - back to base fee, address rehabilitated");
        vm.warp(block.timestamp + 1 days);
        score = oracle.getScore(REFORMED_BOT);
        (, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Fee (pips):", fee);
        assertEq(score, 35);
        assertEq(fee, BASE_FEE);

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

        _quorumScores(OCCASIONAL_MEV, 100, 200, 35);
        _quorumScores(SANDWICH_BOT, 100, 200, 60);
        _quorumScores(REFORMED_BOT, 100, 200, 90);

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

    function _emptyNonSignerSig()
        internal
        pure
        returns (IBLSSignatureChecker.NonSignerStakesAndSignature memory sig)
    {
        sig.apkG2 = BN254.G2Point([uint256(0), uint256(0)], [uint256(0), uint256(0)]);
        sig.sigma = BN254.G1Point(0, 0);
    }

    function _quorumScores(address subject, uint256 fromBlock, uint256 toBlock, uint16 score) internal {
        uint32 taskIndex = tm.taskNumber();

        vm.prank(generator);
        tm.createScoreTask(subject, fromBlock, toBlock, 67, hex"00");

        IGradientShieldTaskManager.ScoreTask memory task = IGradientShieldTaskManager.ScoreTask({
            subject: subject,
            fromBlock: fromBlock,
            toBlock: toBlock,
            taskCreatedBlock: uint32(block.number),
            quorumNumbers: hex"00",
            quorumThresholdPercentage: 67
        });

        IGradientShieldTaskManager.ScoreTaskResponse memory response = IGradientShieldTaskManager.ScoreTaskResponse({
            referenceTaskIndex: taskIndex,
            score: score
        });

        vm.prank(aggregator);
        tm.respondToScoreTask(task, response, _emptyNonSignerSig());
    }

    function _quorumBumps(address subject, uint256 fromBlock, uint256 toBlock, uint16 delta) internal {
        uint16 current = oracle.getScore(subject);
        uint16 newScore = current + delta;
        if (newScore > 100) newScore = 100;
        _quorumScores(subject, fromBlock, toBlock, newScore);
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
}
