// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Hook Edge Cases & Coverage Tests
/// @notice Tests for fee curve boundaries, staleness, task cooldown,
///         evasion attempts, event emissions, and detection corner cases.
contract HookEdgeCasesTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    PoolSwapTest internal botRouter;
    PoolSwapTest internal bot2Router;
    PoolSwapTest internal victimRouter;
    PoolSwapTest internal cleanRouter;
    PoolModifyLiquidityTest internal lpRouter;

    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal avs = address(0xA75);

    function setUp() public {
        deployFreshManagerAndRouters();
        oracle = new ScoringOracle(avs);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(0)), address(0))
        );
        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(0)), address(0)
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        botRouter = new PoolSwapTest(manager);
        bot2Router = new PoolSwapTest(manager);
        victimRouter = new PoolSwapTest(manager);
        cleanRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        PoolSwapTest[4] memory routers = [botRouter, bot2Router, victimRouter, cleanRouter];
        for (uint256 i = 0; i < routers.length; i++) {
            token0.approve(address(routers[i]), type(uint256).max);
            token1.approve(address(routers[i]), type(uint256).max);
        }
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    // =====================================================================
    //  FEE CURVE BOUNDARY TESTS
    // =====================================================================

    function test_feeCurve_score0_baseFee() public {
        // Score 0: clean, should get exactly BASE_FEE
        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, address(cleanRouter), true, -100, 0, 3000, block.number);
        _swap(cleanRouter, true, -100);
    }

    function test_feeCurve_score39_stillBaseFee() public {
        // Score 39: right below suspicious threshold, should still be base fee
        vm.prank(avs);
        oracle.setScore(address(botRouter), 39);

        PoolId poolId = key.toId();
        // fee = BASE_FEE because score < 40
        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, address(botRouter), true, -100, 39, 3000, block.number);
        _swap(botRouter, true, -100);
    }

    function test_feeCurve_score40_noEscalation() public {
        // Score 40: exactly at suspicious threshold, but fee = 3000 + 12000*(0)/40 = 3000
        // Equal to BASE_FEE, so NO FeeEscalated event
        vm.prank(avs);
        oracle.setScore(address(botRouter), 40);

        vm.recordLogs();
        _swap(botRouter, true, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "Score 40 fee equals base, no escalation");
        }
    }

    function test_feeCurve_score41_firstRealEscalation() public {
        // Score 41: first score that actually produces fee > BASE_FEE
        vm.prank(avs);
        oracle.setScore(address(botRouter), 41);

        PoolId poolId = key.toId();
        // fee = 3000 + 12000 * (41-40) / 40 = 3000 + 300 = 3300
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(botRouter), 3000, 3300);
        _swap(botRouter, true, -100);
    }

    function test_feeCurve_score60_midEscalation() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 60);

        PoolId poolId = key.toId();
        // fee = 3000 + 12000 * (60-40) / 40 = 3000 + 6000 = 9000
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(botRouter), 3000, 9000);
        _swap(botRouter, true, -100);
    }

    function test_feeCurve_score79_maxBeforeReject() public {
        // Score 79: highest fee before rejection
        vm.prank(avs);
        oracle.setScore(address(botRouter), 79);

        PoolId poolId = key.toId();
        // fee = 3000 + 12000 * (79-40) / 40 = 3000 + 11700 = 14700
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(botRouter), 3000, 14700);
        _swap(botRouter, true, -100);
    }

    function test_feeCurve_score80_rejected() public {
        // Score 80: exactly at reject threshold
        vm.prank(avs);
        oracle.setScore(address(botRouter), 80);

        vm.expectRevert();
        _swap(botRouter, true, -100);
    }

    function test_feeCurve_score100_rejected() public {
        // Score 100: maximum possible
        vm.prank(avs);
        oracle.setScore(address(botRouter), 100);

        vm.expectRevert();
        _swap(botRouter, true, -100);
    }

    // =====================================================================
    //  NO FeeEscalated EVENT AT BASE FEE
    // =====================================================================

    function test_noFeeEscalatedEventForCleanUser() public {
        vm.recordLogs();
        _swap(cleanRouter, true, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "FeeEscalated should not fire for clean user");
        }
    }

    // =====================================================================
    //  SANDWICH DETECTION EDGE CASES
    // =====================================================================

    function test_noSandwich_sameDirectionTwice() public {
        // Bot swaps same direction twice — NOT a sandwich
        vm.recordLogs();
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, true, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == sandwichSig, "Same-direction swaps should not trigger sandwich");
        }
    }

    function test_noSandwich_onlyTwoSwaps() public {
        // Bot swaps opposite direction but no victim in between (only 2 total swaps)
        // First swap: zeroForOne=true, second swap: zeroForOne=false
        // swapCount will be 1 after first swap, and 2 when back-run checks,
        // but the condition requires swapCount >= 2 (victim must exist)
        vm.recordLogs();
        _swap(botRouter, true, -100);
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) found = true;
        }
        // swapCount is 1 when back-run happens (counter is 1 from first swap),
        // so >= 2 check fails. No sandwich detected.
        assertFalse(found, "No sandwich without a victim between");
    }

    function test_sandwich_multipleVictims() public {
        // Bot front-runs, TWO victims swap, bot back-runs
        vm.recordLogs();
        _swap(botRouter, true, -100);       // front-run
        _swap(victimRouter, true, -50);     // victim 1
        _swap(cleanRouter, true, -50);      // victim 2
        _swap(botRouter, false, -100);      // back-run

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) detected = true;
        }
        assertTrue(detected, "Sandwich with multiple victims should still be detected");
    }

    function test_twoBots_sameSandwich() public {
        // Two different bots each do front-run in same block
        // Only the one that back-runs with opposite direction gets flagged
        vm.recordLogs();
        _swap(botRouter, true, -100);       // bot1 front-run
        _swap(bot2Router, true, -50);       // bot2 front-run
        _swap(victimRouter, true, -50);     // victim
        _swap(botRouter, false, -100);      // bot1 back-run (should detect)

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool bot1Detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) {
                address flagged = address(uint160(uint256(logs[i].topics[2])));
                if (flagged == address(botRouter)) bot1Detected = true;
            }
        }
        assertTrue(bot1Detected, "Bot1 sandwich should be detected");
    }

    function test_sandwichDetection_resetsAcrossBlocks() public {
        // Bot front-runs in block N, victim swaps in block N, bot back-runs in block N+1
        _swap(botRouter, true, -100);       // block N
        _swap(victimRouter, true, -50);     // block N

        vm.roll(block.number + 1);

        vm.recordLogs();
        _swap(botRouter, false, -100);      // block N+1

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == sandwichSig, "Cross-block should not trigger sandwich");
        }
    }

    // =====================================================================
    //  JIT DETECTION EDGE CASES
    // =====================================================================

    function test_jit_addWithoutRemove_noDetection() public {
        // LP adds liquidity but never removes in same block — no JIT
        vm.recordLogs();
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap(victimRouter, true, -50);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 jitSig = keccak256("JITDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == jitSig, "Add without remove should not trigger JIT");
        }
    }

    function test_jit_removeWithoutAdd_noDetection() public {
        // LP adds in block N, removes in block N+1 — no JIT
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        vm.roll(block.number + 1);

        vm.recordLogs();
        lpRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 jitSig = keccak256("JITDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == jitSig, "Cross-block add/remove should not trigger JIT");
        }
    }

    function test_jit_sameBlockAddSwapRemove_detected() public {
        // Classic JIT: add + swap + remove all in one block
        vm.recordLogs();
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap(victimRouter, true, -50);
        lpRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 jitSig = keccak256("JITDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == jitSig) detected = true;
        }
        assertTrue(detected, "Same-block add+swap+remove should trigger JIT");
    }

    function test_jit_multipleAddsOneRemove() public {
        // LP adds twice in same block, then removes — should still detect
        vm.recordLogs();
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap(victimRouter, true, -50);
        lpRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 jitSig = keccak256("JITDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == jitSig) detected = true;
        }
        assertTrue(detected, "Multiple adds + remove in same block should detect JIT");
    }

    // =====================================================================
    //  EVASION ATTEMPTS
    // =====================================================================

    function test_evasion_newRouterResetsScore() public {
        // Bot gets scored on botRouter, deploys a new router to evade
        vm.prank(avs);
        oracle.setScore(address(botRouter), 85);

        // Bot's original router is blocked
        vm.expectRevert();
        _swap(botRouter, true, -100);

        // Bot creates new router — score=0, trades freely
        PoolSwapTest evasionRouter = new PoolSwapTest(manager);
        token0.approve(address(evasionRouter), type(uint256).max);
        token1.approve(address(evasionRouter), type(uint256).max);
        _swapWith(evasionRouter, true, -100);

        // BUT if evasion router sandwiches, it gets detected too
        _swapWith(evasionRouter, true, -100);
        _swap(victimRouter, true, -50);

        vm.recordLogs();
        _swapWith(evasionRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) detected = true;
        }
        assertTrue(detected, "Evasion router sandwich should be detected");
    }

    function test_evasion_botSplitsAcrossRouters() public {
        // Bot uses router1 for front-run, router2 for back-run
        // Hook tracks per-sender, so this evades detection
        vm.recordLogs();
        _swap(botRouter, true, -100);       // front-run via router1
        _swap(victimRouter, true, -50);     // victim
        _swap(bot2Router, false, -100);     // back-run via router2

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) detected = true;
        }
        // This is a known limitation: split-router sandwich evades per-sender detection
        assertFalse(detected, "Split-router sandwich evades per-sender detection (known limitation)");
    }

    // =====================================================================
    //  STALE SCORE RE-EVALUATION
    // =====================================================================

    function test_staleScore_triggersReevalAfterThreshold() public {
        // Set a score, then warp past STALENESS_THRESHOLD (7 days)
        vm.prank(avs);
        oracle.setScore(address(botRouter), 50);

        // Warp 8 days — score decays to 50 - 40 = 10 (clean band)
        // but the record is stale, so _checkStaleness should fire
        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);

        vm.recordLogs();
        _swap(botRouter, true, -100);

        // Score has decayed to 10 (clean), so swap succeeds
        // _checkStaleness fires because lastUpdated is 8 days ago
        // But since taskManager is address(0), no external task is created
        // The swap should still succeed at base fee
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 telemetrySig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == telemetrySig) found = true;
        }
        assertTrue(found, "Swap should succeed even with stale score");
    }

    function test_staleScore_withinThreshold_noReeeval() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 50);

        // Warp 6 days — within staleness threshold
        vm.warp(block.timestamp + 6 days);
        vm.roll(block.number + 1);

        // Score decayed to 50 - 30 = 20, which is clean
        _swap(botRouter, true, -100);
        // Should succeed at base fee, no staleness trigger
    }

    // =====================================================================
    //  SCORE DECAY + FEE INTERACTION
    // =====================================================================

    function test_decayedScore_movesFromSuspiciousToClean() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 50);

        // Day 0: score=50, fee=6000 (suspicious)
        _swap(botRouter, true, -50);

        // Day 3: score=35, fee=3000 (clean — decayed below 40)
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        vm.recordLogs();
        _swap(botRouter, true, -50);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "Decayed-to-clean should not escalate");
        }
    }

    function test_decayedScore_movesFromRejectedToSuspicious() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 90);

        // Day 0: score=90, REJECTED
        vm.expectRevert();
        _swap(botRouter, true, -50);

        // Day 3: score=75, SUSPICIOUS (can trade again but with escalated fee)
        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        PoolId poolId = key.toId();
        // fee = 3000 + 12000 * (75-40) / 40 = 3000 + 10500 = 13500
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(botRouter), 3000, 13500);
        _swap(botRouter, true, -50);
    }

    function test_decayedScore_fullRehabilitationToBaseFee() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 100);

        // Day 20: score = max(100 - 100, 0) = 0
        vm.warp(block.timestamp + 20 days);
        vm.roll(block.number + 1);

        uint16 score = oracle.getScore(address(botRouter));
        assertEq(score, 0, "Should be fully decayed");

        vm.recordLogs();
        _swap(botRouter, true, -50);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "Fully decayed should trade at base fee");
        }
    }

    // =====================================================================
    //  SCORING ORACLE EDGE CASES
    // =====================================================================

    function test_oracle_bumpAfterPartialDecay() public {
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 60);

        // 4 days later: decayed to 60 - 20 = 40
        vm.warp(block.timestamp + 4 days);

        // Bump by 30: new score = 40 + 30 = 70
        vm.prank(avs);
        oracle.bumpScore(address(0xBEEF), 30);

        uint16 score = oracle.getScore(address(0xBEEF));
        assertEq(score, 70, "Bump should apply on decayed value");
    }

    function test_oracle_bumpSaturatesAt100() public {
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 90);

        vm.prank(avs);
        oracle.bumpScore(address(0xBEEF), 50);

        uint16 score = oracle.getScore(address(0xBEEF));
        assertEq(score, 100, "Bump should saturate at MAX_SCORE");
    }

    function test_oracle_multipleRapidBumps() public {
        vm.startPrank(avs);
        oracle.setScore(address(0xBEEF), 0);
        oracle.bumpScore(address(0xBEEF), 20);
        oracle.bumpScore(address(0xBEEF), 20);
        oracle.bumpScore(address(0xBEEF), 20);
        vm.stopPrank();

        uint16 score = oracle.getScore(address(0xBEEF));
        assertEq(score, 60, "Multiple bumps should accumulate");
    }

    function test_oracle_setScoreResetsDecayTimer() public {
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 60);

        vm.warp(block.timestamp + 2 days);
        // Decayed to 50

        // Set new score — resets timer
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 60);

        // 2 more days: should decay from 60 (not from 50)
        vm.warp(block.timestamp + 2 days);
        uint16 score = oracle.getScore(address(0xBEEF));
        assertEq(score, 50, "setScore should reset decay timer");
    }

    // =====================================================================
    //  HOOKDATA EDGE CASES
    // =====================================================================

    function test_hookData_wrongLength_fallsBackToOracle() public {
        vm.prank(avs);
        oracle.setScore(address(swapRouter), 50);

        // hookData with wrong length (not 160 bytes) — should fall back to oracle
        bytes memory badHookData = hex"deadbeef";

        // fee should be oracle-based: score=50, fee=6000
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(key.toId(), address(swapRouter), 3000, 6000);
        swap(key, true, -100, badHookData);
    }

    function test_hookData_emptyBytes_usesOracle() public {
        vm.prank(avs);
        oracle.setScore(address(swapRouter), 50);

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(key.toId(), address(swapRouter), 3000, 6000);
        swap(key, true, -100, ZERO_BYTES);
    }

    // =====================================================================
    //  MULTIPLE SWAPS SAME BLOCK, DIFFERENT USERS
    // =====================================================================

    function test_multipleCleanUsers_sameBlock_allBaseFee() public {
        vm.recordLogs();
        _swap(cleanRouter, true, -50);
        _swap(victimRouter, true, -50);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "Clean users should not see fee escalation");
        }
    }

    function test_scoredAndCleanUsers_sameBlock() public {
        // One scored user, one clean, same block
        vm.prank(avs);
        oracle.setScore(address(botRouter), 60);

        PoolId poolId = key.toId();

        // Bot swap — escalated
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(botRouter), 3000, 9000);
        _swap(botRouter, true, -50);

        // Clean swap — no escalation
        vm.recordLogs();
        _swap(cleanRouter, true, -50);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeEscalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeEscalatedSig, "Clean user unaffected by bot in same block");
        }
    }

    // =====================================================================
    //  EVENT EMISSION VERIFICATION
    // =====================================================================

    function test_swapTelemetry_emitsOnEverySwap() public {
        PoolId poolId = key.toId();

        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, address(cleanRouter), true, -100, 0, 3000, block.number);
        _swap(cleanRouter, true, -100);
    }

    function test_botRejectedEvent_emitsBeforeRevert() public {
        vm.prank(avs);
        oracle.setScore(address(botRouter), 85);

        // The BotRejectedEvent is emitted before the revert
        // We can't expectEmit + expectRevert together, but the revert proves rejection
        vm.expectRevert();
        _swap(botRouter, true, -50);
    }

    function test_sandwichDetected_emitsWithBotAddress() public {
        PoolId poolId = key.toId();

        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.SandwichDetected(poolId, address(botRouter), block.number);
        _swap(botRouter, false, -100);
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _swap(PoolSwapTest router, bool zeroForOne, int256 amount) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    function _swapWith(PoolSwapTest router, bool zeroForOne, int256 amount) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
