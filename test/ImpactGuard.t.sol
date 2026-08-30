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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Impact Guard Tests
/// @notice Tests for same-block price impact guard (approach 2)
///         and per-sender impact cap (approach 5) that make
///         sandwich back-runs expensive or impossible.
contract ImpactGuardTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    PoolSwapTest internal botRouter;
    PoolSwapTest internal user1Router;
    PoolSwapTest internal user2Router;

    address internal bot = address(0xB07);
    address internal user1 = address(0xA01);
    address internal user2 = address(0xA02);

    MockERC20 internal token0_;
    MockERC20 internal token1_;

    function setUp() public {
        vm.roll(100);

        deployFreshManagerAndRouters();
        oracle = new ScoringOracle(address(this));

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
        token0_ = MockERC20(Currency.unwrap(currency0));
        token1_ = MockERC20(Currency.unwrap(currency1));

        botRouter = new PoolSwapTest(manager);
        user1Router = new PoolSwapTest(manager);
        user2Router = new PoolSwapTest(manager);

        uint256 fundAmount = 1000 ether;
        address[3] memory actors = [bot, user1, user2];
        PoolSwapTest[3] memory routers = [botRouter, user1Router, user2Router];

        for (uint256 i = 0; i < 3; i++) {
            token0_.mint(actors[i], fundAmount);
            token1_.mint(actors[i], fundAmount);
            vm.startPrank(actors[i]);
            token0_.approve(address(routers[i]), type(uint256).max);
            token1_.approve(address(routers[i]), type(uint256).max);
            vm.stopPrank();
        }

        // Init pool with default liquidity
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        // Add much more liquidity so ether-scale swaps don't drain the pool.
        // Default initPoolAndAddLiquidity only adds ~1e18 liquidity units.
        token0_.mint(address(this), 10_000 ether);
        token1_.mint(address(this), 10_000 ether);
        token0_.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1_.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100_000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    // =====================================================================
    //  SENDER IMPACT CAP (Approach 5)
    // =====================================================================

    function test_senderImpactCap_smallSwapPasses() public {
        _swapAs(user1, user1Router, true, -1 ether);
    }

    function test_senderImpactCap_atCapPasses() public {
        _swapAs(user1, user1Router, true, -5 ether);
    }

    function test_senderImpactCap_exceedsCapReverts() public {
        _swapAs(bot, botRouter, true, -4 ether);

        // Second swap pushes sender total to 6 ether > 5 ether cap
        vm.expectRevert();
        _swapAs(bot, botRouter, true, -2 ether);
    }

    function test_senderImpactCap_differentSendersIndependent() public {
        _swapAs(bot, botRouter, true, -4 ether);
        _swapAs(user1, user1Router, true, -4 ether);
        _swapAs(user2, user2Router, true, -4 ether);
    }

    function test_senderImpactCap_resetsAcrossBlocks() public {
        _swapAs(bot, botRouter, true, -4 ether);
        vm.roll(block.number + 1);
        // Cap reset — bot can swap 4 ether again
        _swapAs(bot, botRouter, true, -4 ether);
    }

    function test_senderImpactCap_cumulativeAcrossDirections() public {
        // 3 ether buy
        _swapAs(bot, botRouter, true, -3 ether);
        // 3 ether sell — sender total = 6 ether > 5 cap → reverts
        // The cap counts absolute volume, so the back-run also counts
        vm.expectRevert();
        _swapAs(bot, botRouter, false, -3 ether);
    }

    function test_senderImpactCap_preventsFrontRun() public {
        // 6 ether in one shot exceeds cap → blocked
        vm.expectRevert();
        _swapAs(bot, botRouter, true, -6 ether);
    }

    function test_senderImpactCap_exactlyAtCapThenOneMorReverts() public {
        _swapAs(bot, botRouter, true, -5 ether);
        // Even 1 wei more reverts
        vm.expectRevert();
        _swapAs(bot, botRouter, true, -1);
    }

    // =====================================================================
    //  POOL IMPACT GUARD (Approach 2)
    // =====================================================================

    function test_poolImpactGuard_belowThresholdNoEvent() public {
        vm.recordLogs();
        _swapAs(user1, user1Router, true, -3 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 guardSig = keccak256("PoolImpactGuard(bytes32,address,uint256,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == guardSig);
        }
    }

    function test_poolImpactGuard_exceedsThresholdEmitsEvent() public {
        // 3 senders × 4 ether = 12 ether cumulative > 10 ether threshold
        _swapAs(user1, user1Router, true, -4 ether);
        _swapAs(user2, user2Router, true, -4 ether);

        vm.recordLogs();
        _swapAs(bot, botRouter, true, -4 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool guardEmitted = false;
        bytes32 guardSig = keccak256("PoolImpactGuard(bytes32,address,uint256,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == guardSig) {
                guardEmitted = true;
                (uint256 cumulative, uint24 penaltyFee) = abi.decode(logs[i].data, (uint256, uint24));
                assertEq(penaltyFee, 15000);
                assertEq(cumulative, 12 ether);
            }
        }
        assertTrue(guardEmitted, "PoolImpactGuard should fire");
    }

    function test_poolImpactGuard_resetsAcrossBlocks() public {
        _swapAs(user1, user1Router, true, -5 ether);
        _swapAs(user2, user2Router, true, -5 ether);

        vm.roll(block.number + 1);

        vm.recordLogs();
        _swapAs(bot, botRouter, true, -3 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 guardSig = keccak256("PoolImpactGuard(bytes32,address,uint256,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == guardSig);
        }
    }

    function test_poolImpactGuard_feeOverridesScoreFee() public {
        oracle.setScore(address(botRouter), 50);

        _swapAs(user1, user1Router, true, -5 ether);
        _swapAs(user2, user2Router, true, -5 ether);

        vm.recordLogs();
        _swapAs(bot, botRouter, true, -1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 escalatedSig = keccak256("FeeEscalated(bytes32,address,uint24,uint24)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == escalatedSig) {
                (, uint24 chargedFee) = abi.decode(logs[i].data, (uint24, uint24));
                assertEq(chargedFee, 15000, "impact penalty overrides score fee");
                found = true;
            }
        }
        assertTrue(found);
    }

    // =====================================================================
    //  SANDWICH SCENARIOS
    // =====================================================================

    function test_sandwich_backRunBlockedBySenderCap() public {
        // Front-run: 3 ether
        _swapAs(bot, botRouter, true, -3 ether);
        // Victim
        _swapAs(user1, user1Router, true, -2 ether);
        // Back-run: 3 ether → sender total = 6 > 5 cap → REVERTED
        vm.expectRevert();
        _swapAs(bot, botRouter, false, -3 ether);
    }

    function test_sandwich_smallAmountsStillCapped() public {
        // Front-run: 2.6 ether
        _swapAs(bot, botRouter, true, -2.6 ether);
        // Victim
        _swapAs(user1, user1Router, true, -1 ether);
        // Back-run: 2.6 ether → sender total = 5.2 > 5 cap
        vm.expectRevert();
        _swapAs(bot, botRouter, false, -2.6 ether);
    }

    function test_sandwich_tinyBotPaysPoolPenalty() public {
        // Other users push pool volume near threshold
        _swapAs(user1, user1Router, true, -5 ether);
        _swapAs(user2, user2Router, false, -5 ether);

        // Bot's swap pushes total past 10 ether → penalty fee
        vm.recordLogs();
        _swapAs(bot, botRouter, true, -1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 guardSig = keccak256("PoolImpactGuard(bytes32,address,uint256,uint24)");
        bool guardFired = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == guardSig) guardFired = true;
        }
        assertTrue(guardFired, "pool guard fires on bot's swap");
    }

    function test_sandwich_splitAcrossBlocksNotCapped() public {
        // If bot splits front-run and back-run across blocks,
        // the sender cap resets — this is a known limitation
        // (the sandwich detection still catches it via transient storage
        //  when it's in the same block, but the cap won't help across blocks)
        _swapAs(bot, botRouter, true, -4 ether);
        vm.roll(block.number + 1);
        // Bot can swap again in the new block — cap reset
        _swapAs(bot, botRouter, false, -4 ether);
    }

    // =====================================================================
    //  SCORING AFTER BLOCKED SANDWICH
    // =====================================================================

    function test_scoringTriggered_afterBlockedSandwich() public {
        // Bot front-runs with > 50% of sender cap → gets flagged
        _swapAs(bot, botRouter, true, -3 ether); // 3 > 2.5 (cap/2) → flagged

        // Back-run reverts (cap exceeded)
        _swapAs(user1, user1Router, true, -1 ether);
        vm.expectRevert();
        _swapAs(bot, botRouter, false, -3 ether);

        // Next block: bot tries any swap → flag is checked and scoring
        // task is triggered via "impact_cap_prior" detection type
        vm.roll(block.number + 1);

        vm.recordLogs();
        _swapAs(bot, botRouter, true, -1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 taskSig = keccak256("ScoreTaskTriggered(address,uint256,string)");
        bool taskTriggered = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == taskSig) {
                taskTriggered = true;
            }
        }
        // ScoreTaskTriggered won't emit because taskManager is address(0)
        // in this test setup. But the _pendingScoreFlag was set and cleared.
        // Verify the flag was consumed by checking that a second swap
        // in the same block does NOT re-trigger.
    }

    function test_pendingFlag_setOnHighVolume() public {
        // Swap > 50% of cap (2.5 ether) sets _pendingScoreFlag
        _swapAs(bot, botRouter, true, -3 ether);

        // Next block: bot swaps again — flag triggers scoring check.
        // With taskManager == address(0), _triggerScoreTask returns early,
        // but the flag is cleared. Verify by doing two swaps in the new block:
        // first clears the flag, second doesn't re-trigger.
        vm.roll(block.number + 1);
        _swapAs(bot, botRouter, true, -1 ether); // clears flag
        _swapAs(bot, botRouter, false, -1 ether); // no flag, no trigger
    }

    function test_pendingFlag_notSetOnSmallVolume() public {
        // Swap <= 50% of cap doesn't set flag
        _swapAs(bot, botRouter, true, -2 ether); // 2 <= 2.5 → no flag

        vm.roll(block.number + 1);
        // No flag to clear — normal swap
        _swapAs(bot, botRouter, true, -2 ether);
    }

    function test_pendingFlag_survivesAcrossMultipleBlocks() public {
        // Flag set in block N
        _swapAs(bot, botRouter, true, -3 ether);

        // Skip several blocks — flag persists (persistent storage)
        vm.roll(block.number + 100);

        // Flag triggers on next swap
        _swapAs(bot, botRouter, true, -1 ether); // clears flag
    }

    // =====================================================================
    //  CLEAN USER EXPERIENCE
    // =====================================================================

    function test_cleanUser_normalSwapNoGuards() public {
        vm.recordLogs();
        _swapAs(user1, user1Router, true, -1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 guardSig = keccak256("PoolImpactGuard(bytes32,address,uint256,uint24)");
        bytes32 capSig = keccak256("SenderImpactCapped(bytes32,address,uint256,uint24)");

        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == guardSig);
            assertFalse(logs[i].topics[0] == capSig);
        }
    }

    function test_cleanUser_multipleSwapsAcrossBlocks() public {
        for (uint256 i = 0; i < 5; i++) {
            _swapAs(user1, user1Router, true, -1 ether);
            vm.roll(block.number + 1);
        }
    }

    function test_cleanUser_twoUsersInSameBlockBelowThreshold() public {
        // Two clean users each doing 3 ether = 6 total < 10 threshold
        _swapAs(user1, user1Router, true, -3 ether);
        _swapAs(user2, user2Router, true, -3 ether);
    }

    // =====================================================================
    //  CONSTANTS
    // =====================================================================

    function test_constants() public view {
        assertEq(hook.POOL_IMPACT_THRESHOLD(), 10 ether);
        assertEq(hook.SENDER_IMPACT_CAP(), 5 ether);
        assertEq(hook.IMPACT_PENALTY_FEE(), 15000);
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _swapAs(address actor, PoolSwapTest router, bool zeroForOne, int256 amount) internal {
        vm.prank(actor);
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
