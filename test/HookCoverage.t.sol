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

/// @dev Mock that records task creation calls so we can verify the hook triggers them.
contract MockTaskCreator is IScoreTaskCreator {
    struct TaskCall {
        address subject;
        uint256 fromBlock;
        uint256 toBlock;
        uint32 quorumThresholdPercentage;
    }

    TaskCall[] public tasks;
    uint32 public taskCount;
    bool public shouldRevert;

    mapping(address => uint32) internal _latestTask;

    function createScoreTask(
        address subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage,
        bytes calldata
    ) external override {
        if (shouldRevert) revert("MockTaskCreator: forced revert");
        tasks.push(TaskCall(subject, fromBlock, toBlock, quorumThresholdPercentage));
        _latestTask[subject] = taskCount;
        taskCount++;
    }

    function taskNumber() external view override returns (uint32) {
        return taskCount;
    }

    function latestTaskForSubject(address subject) external view override returns (uint32) {
        return _latestTask[subject];
    }

    function getTask(uint256 i) external view returns (TaskCall memory) {
        return tasks[i];
    }

    function setShouldRevert(bool val) external {
        shouldRevert = val;
    }
}

/// @title GradientShieldHook Deep Coverage Tests
/// @notice Exercises _triggerScoreTask, task cooldown, _checkStaleness,
///         _resolveScore paths, transient storage isolation, constructor,
///         and combined detection+scoring+task flows.
contract HookCoverageTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;
    MockTaskCreator internal mockTM;

    PoolSwapTest internal botRouter;
    PoolSwapTest internal bot2Router;
    PoolSwapTest internal victimRouter;
    PoolSwapTest internal cleanRouter;
    PoolModifyLiquidityTest internal lpRouter;

    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal avs = address(0xA75);

    // Trader identities — the hook attributes by trader, not by router.
    address internal constant BOT1 = address(0xB01);
    address internal constant BOT2 = address(0xB02);
    address internal constant VICTIM = address(0xA01);

    function setUp() public {
        deployFreshManagerAndRouters();
        oracle = new ScoringOracle(avs);
        mockTM = new MockTaskCreator();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(mockTM)), address(0))
        );
        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(mockTM)), address(0)
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

        // Roll past TASK_COOLDOWN_BLOCKS so default _lastTaskBlock[addr]=0 doesn't
        // cause the cooldown guard (0 + 50 > block.number) to early-return
        vm.roll(100);
    }

    // =====================================================================
    //  CONSTRUCTOR
    // =====================================================================

    function test_constructor_setsImmutables() public view {
        assertEq(address(hook.oracle()), address(oracle));
        assertEq(address(hook.taskManager()), address(mockTM));
        assertEq(hook.attestor(), address(0));
    }

    function test_constructor_poolManagerSet() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    // =====================================================================
    //  _triggerScoreTask — SANDWICH TRIGGERS TASK
    // =====================================================================

    function test_sandwichTriggersTask() public {
        // Sandwich pattern should auto-trigger a scoring task on the mockTM
        assertEq(mockTM.taskCount(), 0);

        _swap(botRouter, true, -100);      // front-run
        _swap(victimRouter, true, -50);    // victim
        _swap(botRouter, false, -100);     // back-run -> SandwichDetected + task

        assertEq(mockTM.taskCount(), 1, "Should create one scoring task");

        MockTaskCreator.TaskCall memory task = mockTM.getTask(0);
        assertEq(task.subject, tx.origin, "Task subject should be bot");
        assertEq(task.quorumThresholdPercentage, 67, "Should use DETECTION_QUORUM_THRESHOLD");
    }

    function test_sandwichTriggersScoreTaskEvent() public {
        vm.recordLogs();
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 taskSig = keccak256("ScoreTaskTriggered(address,uint256,string)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == taskSig) {
                found = true;
                address subject = address(uint160(uint256(logs[i].topics[1])));
                assertEq(subject, tx.origin);
            }
        }
        assertTrue(found, "ScoreTaskTriggered event should fire");
    }

    // =====================================================================
    //  _triggerScoreTask — JIT TRIGGERS TASK
    // =====================================================================

    function test_jitTriggersTask() public {
        assertEq(mockTM.taskCount(), 0);

        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap(victimRouter, true, -50);
        lpRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(mockTM.taskCount(), 1, "JIT should create one scoring task");
        MockTaskCreator.TaskCall memory task = mockTM.getTask(0);
        assertEq(task.subject, tx.origin, "Task subject should be JIT LP");
    }

    // =====================================================================
    //  TASK COOLDOWN — TASK_COOLDOWN_BLOCKS prevents spam
    // =====================================================================

    function test_taskCooldown_preventsRepeatTasks() public {
        // First sandwich: triggers task
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);
        assertEq(mockTM.taskCount(), 1);

        // Second sandwich in same block range (within cooldown): no new task
        vm.roll(block.number + 1);
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);
        assertEq(mockTM.taskCount(), 1, "Cooldown should prevent second task");
    }

    function test_taskCooldown_allowsAfterCooldownExpires() public {
        // First sandwich
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);
        assertEq(mockTM.taskCount(), 1);

        // Roll past TASK_COOLDOWN_BLOCKS (50)
        vm.roll(block.number + 51);

        // Second sandwich: cooldown expired, new task created
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);
        assertEq(mockTM.taskCount(), 2, "Should allow task after cooldown expires");
    }

    function test_taskCooldown_perAddress() public {
        // Bot1 sandwich: triggers a task for bot1
        _swapAsTrader(BOT1, botRouter, true, -100);
        _swapAsTrader(VICTIM, victimRouter, true, -50);
        _swapAsTrader(BOT1, botRouter, false, -100);
        assertEq(mockTM.taskCount(), 1);

        // Bot2 sandwich in the next block: a different trader, so the cooldown
        // on bot1 must not suppress it.
        vm.roll(block.number + 1);
        _swapAsTrader(BOT2, bot2Router, true, -100);
        _swapAsTrader(VICTIM, victimRouter, true, -50);
        _swapAsTrader(BOT2, bot2Router, false, -100);
        assertEq(mockTM.taskCount(), 2, "Different trader should get own task regardless of cooldown");
    }

    // =====================================================================
    //  _triggerScoreTask — TRY/CATCH HANDLES REVERT
    // =====================================================================

    function test_taskCreatorRevert_doesNotBreakSwap() public {
        // Make the task creator revert
        mockTM.setShouldRevert(true);

        // Sandwich should still work (detection occurs, task creation fails silently)
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100); // back-run succeeds even though task creation reverts

        assertEq(mockTM.taskCount(), 0, "Task creation should have failed");
    }

    // =====================================================================
    //  _checkStaleness — TRIGGERS RESCORE TASK FOR STALE SCORES
    // =====================================================================

    function test_staleness_decayedToZero_noTask() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 30);

        // Warp 8 days: score decays to max(30-40, 0) = 0
        // score=0 means `if (score > 0) _checkStaleness(sender)` won't fire
        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);

        uint256 tasksBefore = mockTM.taskCount();
        _swap(botRouter, true, -100);
        assertEq(mockTM.taskCount(), tasksBefore, "Decayed-to-zero should not trigger staleness task");
    }

    function test_staleness_triggersTaskWhenScoreStillPositive() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 60); // decays to 60-40=20 after 8 days

        vm.warp(block.timestamp + 8 days);
        vm.roll(block.number + 1);

        uint256 tasksBefore = mockTM.taskCount();
        _swap(botRouter, true, -100); // score=20, still > 0, staleness check fires

        // _checkStaleness sees lastUpdated is 8 days ago (> 7 day threshold)
        // and triggers a "stale" re-eval task
        assertGt(mockTM.taskCount(), tasksBefore, "Stale score should trigger rescore task");
    }

    function test_staleness_noTaskWhenFresh() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 50);

        // Only 1 day later — well within staleness threshold
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        uint256 tasksBefore = mockTM.taskCount();
        _swap(botRouter, true, -100);
        assertEq(mockTM.taskCount(), tasksBefore, "Fresh score should not trigger rescore");
    }

    function test_staleness_noTaskWhenScoreIsZero() public {
        // Unseen address: score=0, _checkStaleness guard `if (score > 0)` is false
        uint256 tasksBefore = mockTM.taskCount();
        _swap(cleanRouter, true, -100);
        assertEq(mockTM.taskCount(), tasksBefore, "Zero score should skip staleness check");
    }

    function test_staleness_noTaskWhenNoRecord() public {
        // rawRecord.lastUpdated == 0 for never-scored address
        uint256 tasksBefore = mockTM.taskCount();
        _swap(cleanRouter, true, -100);
        assertEq(mockTM.taskCount(), tasksBefore);
    }

    // =====================================================================
    //  _computeFee — COMPLETE RANGE
    // =====================================================================

    function test_computeFee_score50_is6000() public {
        PoolSwapTest r = new PoolSwapTest(manager);
        token0.approve(address(r), type(uint256).max);
        token1.approve(address(r), type(uint256).max);
        vm.prank(avs);
        oracle.setScore(tx.origin, 50);

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 6000);
        _swapWith(r, true, -50);
    }

    function test_computeFee_score79_is14700() public {
        PoolSwapTest r = new PoolSwapTest(manager);
        token0.approve(address(r), type(uint256).max);
        token1.approve(address(r), type(uint256).max);
        vm.prank(avs);
        oracle.setScore(tx.origin, 79);

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 14700);
        _swapWith(r, true, -50);
    }

    // =====================================================================
    //  _beforeSwap — FULL FLOW: detect + score check + fee + telemetry
    // =====================================================================

    function test_beforeSwap_fullFlow_cleanUser() public {
        vm.recordLogs();
        _swap(cleanRouter, true, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 telSig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        bool hasTelemetry = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == telSig) hasTelemetry = true;
        }
        assertTrue(hasTelemetry, "SwapTelemetry must fire for every swap");
    }

    function test_beforeSwap_fullFlow_escalatedUser() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 65);

        vm.recordLogs();
        _swap(botRouter, true, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 telSig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        bytes32 feeSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        bool hasTelemetry = false;
        bool hasFeeEscalated = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == telSig) hasTelemetry = true;
            if (logs[i].topics[0] == feeSig) hasFeeEscalated = true;
        }
        assertTrue(hasTelemetry, "SwapTelemetry must fire");
        assertTrue(hasFeeEscalated, "FeeEscalated must fire for scored user");
    }

    function test_beforeSwap_rejectedUser_emitsThenReverts() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 85);

        vm.expectRevert();
        _swap(botRouter, true, -100);
    }

    // =====================================================================
    //  TRANSIENT STORAGE ISOLATION — DIFFERENT POOLS
    // =====================================================================

    function test_transientStorage_isolatedPerPool() public {
        // Create a second pool with the same hook
        PoolKey memory key2;
        {
            MockERC20 tokenA = new MockERC20("TokenA", "A", 18);
            MockERC20 tokenB = new MockERC20("TokenB", "B", 18);
            tokenA.mint(address(this), 1000 ether);
            tokenB.mint(address(this), 1000 ether);

            // Sort tokens
            (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
                ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
                : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

            // Approve for modifyLiquidityRouter and swapRouter
            MockERC20(Currency.unwrap(c0)).approve(address(modifyLiquidityRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(modifyLiquidityRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c0)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(swapRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c0)).approve(address(botRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(botRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c0)).approve(address(victimRouter), type(uint256).max);
            MockERC20(Currency.unwrap(c1)).approve(address(victimRouter), type(uint256).max);

            key2 = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
            manager.initialize(key2, SQRT_PRICE_1_1);
            modifyLiquidityRouter.modifyLiquidity(key2, LIQUIDITY_PARAMS, ZERO_BYTES);
        }

        // Bot front-runs on pool 1
        _swap(botRouter, true, -100);
        // Victim on pool 2 — should NOT count toward sandwich on pool 1
        _swapOnKey(victimRouter, key2, true, -50);

        vm.recordLogs();
        // Bot back-runs on pool 1 — but there was no victim on pool 1
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool detected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) detected = true;
        }
        // No sandwich because pool 1 only had 2 swaps (bot front + bot back), no victim
        assertFalse(detected, "Different pool swaps should not cross-contaminate detection");
    }

    // =====================================================================
    //  TRANSIENT STORAGE — CLEARS ACROSS TRANSACTIONS
    // =====================================================================

    function test_transientStorage_clearsAcrossBlocks() public {
        // Block N: bot does one swap
        _swap(botRouter, true, -100);

        // Block N+1: bot does opposite swap — should NOT be sandwich
        // because transient storage cleared at end of block N's transaction
        vm.roll(block.number + 1);

        vm.recordLogs();
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == sandwichSig);
        }
    }

    // =====================================================================
    //  COMBINED FLOW: detection -> task -> scoring -> escalation
    // =====================================================================

    function test_fullPipeline_sandwichToEscalation() public {
        // Step 1: Sandwich detected, task triggered
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(botRouter, false, -100);

        assertEq(mockTM.taskCount(), 1);
        assertEq(mockTM.getTask(0).subject, tx.origin);

        // Step 2: AVS scores the bot (simulating quorum response)
        vm.prank(avs);
        oracle.setScore(tx.origin, 65);

        // Step 3: Bot's next swap gets escalated fee
        vm.roll(block.number + 1);
        PoolId poolId = key.toId();

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 10500);
        _swap(botRouter, true, -50);
    }

    function test_fullPipeline_jitToEscalation() public {
        // JIT detected, task triggered
        lpRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swap(victimRouter, true, -50);
        lpRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        assertEq(mockTM.taskCount(), 1);
        assertEq(mockTM.getTask(0).subject, tx.origin);
    }

    // =====================================================================
    //  OVERRIDE_FEE_FLAG — fee override is applied
    // =====================================================================

    function test_feeOverrideFlag_isSet() public {
        // Verify the hook returns OVERRIDE_FEE_FLAG with the fee
        // If the flag wasn't set, the pool would use its static fee instead
        // We verify indirectly: a scored user should pay the escalated fee
        vm.prank(avs);
        oracle.setScore(tx.origin, 60);

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        // fee = 3000 + 12000 * (60-40) / 40 = 9000
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 9000);
        _swap(botRouter, true, -50);
    }

    // =====================================================================
    //  SANDWICH DETECTION — SWAP COUNTER LOGIC
    // =====================================================================

    function test_sandwichCounter_needsVictimBetween() public {
        // Bot does front+back with no victim: swapCount = 1 when back-run checks
        // (counter incremented AFTER check, so back-run sees count=1, needs >=2)
        vm.recordLogs();
        _swap(botRouter, true, -100);
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == sandwichSig);
        }
    }

    function test_sandwichCounter_threeVictims() public {
        _swap(botRouter, true, -100);
        _swap(victimRouter, true, -50);
        _swap(cleanRouter, true, -50);
        _swap(bot2Router, true, -50);

        vm.recordLogs();
        _swap(botRouter, false, -100);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) found = true;
        }
        assertTrue(found, "Sandwich with 3 victims should be detected");
    }

    // =====================================================================
    //  FIRST SWAP SLOT — DIRECTION RECORDED ONCE
    // =====================================================================

    function test_firstSwapDirection_onlyRecordedOnce() public {
        // Bot swaps zeroForOne=true, then again zeroForOne=true
        // The second swap should NOT overwrite the first direction
        // So a third swap in the opposite direction should still match the first
        _swap(botRouter, true, -100);
        _swap(botRouter, true, -50);  // same direction, first slot unchanged
        _swap(victimRouter, true, -50);

        vm.recordLogs();
        _swap(botRouter, false, -100);  // opposite of FIRST recorded direction

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sandwichSig = keccak256("SandwichDetected(bytes32,address,uint256)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sandwichSig) found = true;
        }
        assertTrue(found, "Should detect sandwich based on first recorded direction");
    }

    // =====================================================================
    //  HOOK PERMISSIONS COMPLETE CHECK
    // =====================================================================

    function test_hookPermissions_complete() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // =====================================================================
    //  CONSTANTS VERIFICATION
    // =====================================================================

    function test_constants() public view {
        assertEq(hook.SUSPICIOUS_THRESHOLD(), 40);
        assertEq(hook.REJECT_THRESHOLD(), 80);
        assertEq(hook.BASE_FEE(), 3000);
        assertEq(hook.MAX_ESCALATED_FEE(), 15000);
        assertEq(hook.DETECTION_QUORUM_THRESHOLD(), 67);
        assertEq(hook.DETECTION_LOOKBACK(), 10);
        assertEq(hook.TASK_COOLDOWN_BLOCKS(), 50);
        assertEq(hook.STALENESS_THRESHOLD(), 7 days);
    }

    // =====================================================================
    //  BOTH DIRECTIONS — SWAP TELEMETRY
    // =====================================================================

    function test_swapBothDirections_telemetry() public {
        PoolId poolId = key.toId();

        // zeroForOne = true
        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, tx.origin, true, -50, 0, 3000, block.number);
        _swap(cleanRouter, true, -50);

        // zeroForOne = false
        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, tx.origin, false, -50, 0, 3000, block.number);
        _swap(cleanRouter, false, -50);
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

    /// @dev Swaps with `trader` as tx.origin. msg.sender stays this test
    ///      contract, which holds the tokens, so distinct traders can be
    ///      modelled without funding each EOA.
    function _swapAsTrader(address trader, PoolSwapTest router, bool zeroForOne, int256 amount) internal {
        vm.prank(address(this), trader);
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

    function _swapOnKey(PoolSwapTest router, PoolKey memory k, bool zeroForOne, int256 amount) internal {
        router.swap(
            k,
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

/// @title Hook with Attestor — coverage for _resolveScore attestation paths
contract HookAttestorCoverageTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;
    MockTaskCreator internal mockTM;

    uint256 internal attestorPk = 0xA11CE;
    address internal attestorAddr;
    address internal avs = address(0xA75);

    function setUp() public {
        attestorAddr = vm.addr(attestorPk);
        deployFreshManagerAndRouters();
        oracle = new ScoringOracle(avs);
        mockTM = new MockTaskCreator();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(mockTM)), attestorAddr)
        );
        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(mockTM)), attestorAddr
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        deployMintAndApprove2Currencies();

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function test_attestor_setCorrectly() public view {
        assertEq(hook.attestor(), attestorAddr);
    }

    function test_attestation_validScore_overridesOracle() public {
        // Oracle says 0, attestation says 50
        vm.prank(avs);
        oracle.setScore(tx.origin, 0);

        bytes memory hookData = _signAttestation(tx.origin, 50, uint64(block.timestamp + 1 hours));

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 6000);
        swap(key, true, -100, hookData);
    }

    function test_attestation_expired_fallsToOracle() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 60);

        bytes memory hookData = _signAttestation(tx.origin, 0, uint64(block.timestamp - 1));

        // Expired → falls back to oracle (score=60, fee=9000)
        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 9000);
        swap(key, true, -100, hookData);
    }

    function test_attestation_wrongSigner_fallsToOracle() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 55);

        // Sign with wrong key
        uint256 wrongPk = 0xBAD;
        bytes32 innerHash = keccak256(
            abi.encodePacked(address(swapRouter), uint16(0), uint64(block.timestamp + 1 hours), block.chainid, address(hook))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory hookData = abi.encode(uint16(0), uint64(block.timestamp + 1 hours), v, r, s);

        // Wrong signer → falls back to oracle (score=55)
        // fee = 3000 + 12000 * (55-40) / 40 = 3000 + 4500 = 7500
        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 7500);
        swap(key, true, -100, hookData);
    }

    function test_attestation_wrongLength_fallsToOracle() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 45);

        // 4 bytes, not 160
        bytes memory hookData = hex"deadbeef";

        // fee = 3000 + 12000 * (45-40) / 40 = 3000 + 1500 = 4500
        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 4500);
        swap(key, true, -100, hookData);
    }

    function test_attestation_rejectsBot() public {
        bytes memory hookData = _signAttestation(tx.origin, 90, uint64(block.timestamp + 1 hours));

        vm.expectRevert();
        swap(key, true, -100, hookData);
    }

    function test_attestation_cleanScore_baseFee() public {
        bytes memory hookData = _signAttestation(tx.origin, 10, uint64(block.timestamp + 1 hours));

        // Attested score=10, clean → base fee, no escalation
        vm.recordLogs();
        swap(key, true, -100, hookData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 feeSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == feeSig, "Clean attested score should not escalate");
        }
    }

    function _signAttestation(address sender, uint16 score, uint64 expiry) internal view returns (bytes memory) {
        bytes32 innerHash = keccak256(abi.encodePacked(sender, score, expiry, block.chainid, address(hook)));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);
        return abi.encode(score, expiry, v, r, s);
    }
}
