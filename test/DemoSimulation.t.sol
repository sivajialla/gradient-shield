// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

import {ECDSAStakeRegistry} from "eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IECDSAStakeRegistryTypes} from "eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {ISignatureUtilsMixinTypes} from
    "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtilsMixin.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {DelegationMock} from "eigenlayer-middleware/test/mocks/DelegationMock.sol";
import {AVSDirectoryMock} from "eigenlayer-middleware/test/mocks/AVSDirectoryMock.sol";
import {AllocationManagerMock} from "eigenlayer-middleware/test/mocks/AllocationManagerMock.sol";
import {RewardsCoordinatorMock} from "eigenlayer-middleware/test/mocks/RewardsCoordinatorMock.sol";
import {ERC20Mock} from "eigenlayer-middleware/test/mocks/ERC20Mock.sol";

contract DemoSimulationTest is Test {
    ScoringOracle internal oracle;
    GradientShieldServiceManager internal sm;
    ECDSAStakeRegistry internal stakeRegistry;

    uint256 internal operatorPk = 0xA11CE;
    address internal operatorAddr;
    address internal deployer = address(0xDEAD);

    address internal constant CLEAN_TRADER = address(0x1111);
    address internal constant OCCASIONAL_MEV = address(0x2222);
    address internal constant SANDWICH_BOT = address(0x3333);
    address internal constant REFORMED_BOT = address(0x4444);

    uint16 internal constant SUSPICIOUS_THRESHOLD = 40;
    uint16 internal constant REJECT_THRESHOLD = 80;
    uint24 internal constant BASE_FEE = 3000;
    uint24 internal constant ESCALATION_MULTIPLIER = 3;

    function setUp() public {
        operatorAddr = vm.addr(operatorPk);

        DelegationMock delegationMock = new DelegationMock();
        AVSDirectoryMock avsDirectoryMock = new AVSDirectoryMock();
        AllocationManagerMock allocationManagerMock = new AllocationManagerMock();
        RewardsCoordinatorMock rewardsCoordinatorMock = new RewardsCoordinatorMock();

        stakeRegistry = new ECDSAStakeRegistry(IDelegationManager(address(delegationMock)));
        oracle = new ScoringOracle(address(0));

        GradientShieldServiceManager impl = new GradientShieldServiceManager(
            address(avsDirectoryMock),
            address(stakeRegistry),
            address(rewardsCoordinatorMock),
            address(delegationMock),
            address(allocationManagerMock),
            oracle
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GradientShieldServiceManager.initialize, (deployer, deployer))
        );
        sm = GradientShieldServiceManager(address(proxy));

        IStrategy mockStrategy = IStrategy(address(new ERC20Mock()));
        IECDSAStakeRegistryTypes.StrategyParams[] memory strategyParams =
            new IECDSAStakeRegistryTypes.StrategyParams[](1);
        strategyParams[0] = IECDSAStakeRegistryTypes.StrategyParams({
            strategy: mockStrategy,
            multiplier: 10_000
        });
        stakeRegistry.initialize(
            address(sm), 0, IECDSAStakeRegistryTypes.Quorum({strategies: strategyParams})
        );

        oracle.setAvs(address(sm));

        delegationMock.setIsOperator(operatorAddr, true);
        delegationMock.setOperatorShares(operatorAddr, mockStrategy, 1000 ether);

        ISignatureUtilsMixinTypes.SignatureWithSaltAndExpiry memory emptySig;
        emptySig.expiry = type(uint256).max;
        vm.prank(operatorAddr);
        stakeRegistry.registerOperatorWithSignature(emptySig, operatorAddr);
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

        console2.log("");
        console2.log("  Round 2 (1 day later): Bot keeps sandwiching");
        vm.warp(block.timestamp + 1 days);
        _operatorBumps(SANDWICH_BOT, 200, 300, 25);

        score = oracle.getScore(SANDWICH_BOT);
        (band, fee) = _feeDecision(score);
        console2.log("  Score:    ", score);
        console2.log("  Band:     ", band);
        console2.log("  Fee (pips):", fee);
        console2.log("  Result:    Still allowed at 3x, getting close to rejection");
        assertEq(score, 75);

        console2.log("");
        console2.log("  Round 3 (same day): Bot STILL at it");
        _operatorBumps(SANDWICH_BOT, 300, 400, 20);

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
        console2.log("  Day 0: Caught in an aggressive sandwich, scored 85");
        _operatorScores(REFORMED_BOT, 100, 200, 85);

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

        _operatorScores(OCCASIONAL_MEV, 100, 200, 35);
        _operatorScores(SANDWICH_BOT, 100, 200, 60);
        _operatorScores(REFORMED_BOT, 100, 200, 90);

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

    function _operatorScores(address subject, uint32 fromBlock, uint32 toBlock, uint16 score) internal {
        uint32 taskId = sm.createScoreTask(subject, fromBlock, toBlock);

        bytes32 messageHash = keccak256(abi.encodePacked(taskId, subject, score));
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSignedHash);

        vm.prank(operatorAddr);
        sm.respondToTask(taskId, score, abi.encodePacked(r, s, v));
    }

    function _operatorBumps(address subject, uint32 fromBlock, uint32 toBlock, uint16 delta) internal {
        uint16 current = oracle.getScore(subject);
        uint16 newScore = current + delta;
        if (newScore > 100) newScore = 100;
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
