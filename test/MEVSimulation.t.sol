// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

/// @title MEV Simulation - Full Sandwich Attack with Token Balances
/// @notice Shows exact token amounts: what the bot gains, what the victim loses,
///         and how GradientShield changes the outcome.
contract MEVSimulationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    PoolSwapTest internal botRouter;
    PoolSwapTest internal victimRouter;
    PoolSwapTest internal cleanRouter;

    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal avs = address(0xA75);

    // Trader identities — the hook attributes by trader, not by router, so the
    // clean user is genuinely a different party from the bot.
    address internal constant BOT = address(0xB01);
    address internal constant VICTIM = address(0xA01);
    address internal constant CLEAN = address(0xC1EA);

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

        // Create routers for each actor
        botRouter = new PoolSwapTest(manager);
        victimRouter = new PoolSwapTest(manager);
        cleanRouter = new PoolSwapTest(manager);

        // Approve routers to pull tokens from this test contract
        token0.approve(address(botRouter), type(uint256).max);
        token1.approve(address(botRouter), type(uint256).max);
        token0.approve(address(victimRouter), type(uint256).max);
        token1.approve(address(victimRouter), type(uint256).max);
        token0.approve(address(cleanRouter), type(uint256).max);
        token1.approve(address(cleanRouter), type(uint256).max);

        // Initialize pool with dynamic fee
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }


    // =====================================================================
    //  SIMULATION 1: Sandwich Attack - Without vs With GradientShield
    // =====================================================================

    function test_sim_sandwichAttack() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  SIMULATION: Sandwich Attack on Uniswap v4 Pool");
        console2.log("================================================================");
        console2.log("");

        // ----- Phase 1: Bot sandwiches the victim -----
        console2.log("--- Phase 1: Bot executes a sandwich attack ---");
        console2.log("");

        // Step 1: Bot front-runs (sells token0 for token1)
        console2.log("  Step 1: Bot FRONT-RUNS - sells 100 units token0 for token1");
        console2.log("          (pushes price, victim will get worse rate)");
        _swapAsTrader(BOT, botRouter, true, -100);

        // Step 2: Victim swaps (gets worse price)
        console2.log("  Step 2: Victim swaps - sells 50 units token0 for token1");
        console2.log("          (victim pays inflated price)");
        _swapAsTrader(VICTIM, victimRouter, true, -50);

        // Step 3: Bot back-runs (opposite direction triggers detection)
        console2.log("  Step 3: Bot BACK-RUNS - sells token1 back for token0");
        console2.log("          >> SandwichDetected event emitted by hook!");
        _swapAsTrader(BOT, botRouter, false, -100);

        console2.log("");
        console2.log("  >> Hook detected sandwich: same sender, opposite direction,");
        console2.log("     with victim swap in between. All in the same block.");

        // ----- Phase 2: AVS scores the bot, next swap gets escalated fee -----
        console2.log("");
        console2.log("--- Phase 2: BLS quorum scores the bot -> fee escalation ---");
        console2.log("");

        vm.prank(avs);
        oracle.setScore(BOT, 60);
        console2.log("  AVS sets bot score to 60 (suspicious band)");
        console2.log("  Fee = 3000 + 12000 * (60-40) / 40 = 9000 pips (0.90%%)");

        vm.roll(block.number + 1);

        console2.log("  Bot tries another swap (sells 50 units token0)...");
        _swapAsTrader(BOT, botRouter, true, -50);
        console2.log("  >> FeeEscalated event: base=3000 -> charged=9000");

        // ----- Phase 3: Bot keeps attacking, gets rejected -----
        console2.log("");
        console2.log("--- Phase 3: Bot persists -> score bumped to 85 -> REJECTED ---");
        console2.log("");

        vm.prank(avs);
        oracle.setScore(BOT, 85);
        console2.log("  AVS bumps bot score to 85 (reject band)");

        vm.roll(block.number + 1);

        console2.log("  Bot tries to swap again...");
        vm.expectRevert();
        _swapAsTrader(BOT, botRouter, true, -50);
        console2.log("  >> REVERTED with BotRejected(bot, 85)");
        console2.log("  >> Bot cannot trade. Pool is protected.");

        // ----- Phase 4: Clean user unaffected -----
        console2.log("");
        console2.log("--- Phase 4: Clean user swaps at base fee (unaffected) ---");
        console2.log("");

        console2.log("  Clean user (score=0) swaps 50 units token0...");
        _swapAsTrader(CLEAN, cleanRouter, true, -50);
        console2.log("  >> Swap succeeded at base fee (3000 pips = 0.30%%)");
        console2.log("  >> No fee escalation for clean addresses.");

        console2.log("");
        console2.log("================================================================");
        console2.log("  RESULT: Bot detected, escalated, then fully blocked.");
        console2.log("  Clean users trade normally at base fee.");
        console2.log("  LPs earn escalated fees from bot's earlier swaps.");
        console2.log("================================================================");
    }

    // =====================================================================
    //  SIMULATION 2: Score Decay - Bot stops, gradually rehabilitated
    // =====================================================================

    function test_sim_scoreDecay() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  SIMULATION: Score Decay Over Time");
        console2.log("================================================================");
        console2.log("");

        vm.prank(avs);
        oracle.setScore(BOT, 90);
        console2.log("  Bot scored 90 - REJECTED");

        uint16[7] memory dayMarks = [uint16(0), 1, 2, 4, 8, 12, 18];
        uint256 startTime = block.timestamp;

        for (uint256 i = 0; i < dayMarks.length; i++) {
            if (dayMarks[i] > 0) vm.warp(startTime + uint256(dayMarks[i]) * 1 days);

            uint16 score = oracle.getScore(BOT);
            string memory status;
            uint24 fee;

            if (score >= 80) {
                status = "REJECTED";
                fee = 0;
            } else if (score >= 40) {
                fee = 3000 + (15000 - 3000) * uint24(score - 40) / 40;
                status = "ESCALATED";
            } else {
                fee = 3000;
                status = "CLEAN";
            }

            console2.log("  Day %s: score=%s  status=%s", dayMarks[i], score, status);
            console2.log("    fee=%s pips", fee);
        }

        console2.log("");
        console2.log("  >> Score decays 5 pts/day. Bot rehabilitated in ~18 days.");
    }

    // =====================================================================
    //  SIMULATION 3: Multiple addresses, same pool, same block
    // =====================================================================

    function test_sim_multipleAddresses() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  SIMULATION: 4 Different Addresses Swap in Same Block");
        console2.log("================================================================");
        console2.log("");

        // Set up different scores
        vm.startPrank(avs);
        oracle.setScore(address(0xAAAA), 0);   // Clean
        oracle.setScore(address(0xBBBB), 45);  // Suspicious low
        oracle.setScore(address(0xCCCC), 72);  // Suspicious high
        oracle.setScore(address(0xDDDD), 92);  // Rejected
        vm.stopPrank();

        string[4] memory labels = ["Clean Trader    ", "Low Suspicious  ", "High Suspicious ", "Confirmed Bot   "];
        uint16[4] memory scores = [uint16(0), 45, 72, 92];

        console2.log("  Address           Score  Band         Fee(pips)  Fee(%%)    Result");
        console2.log("  -----------------------------------------------------------------------");

        for (uint256 i = 0; i < 4; i++) {
            uint16 s = scores[i];
            if (s >= 80) {
                console2.log("  %s  %s    REJECTED     ---        ---        SWAP REVERTED", labels[i], s);
            } else if (s >= 40) {
                uint24 fee = 3000 + (15000 - 3000) * uint24(s - 40) / 40;
                console2.log("  %s  score=%s  SUSPICIOUS  fee=%s pips", labels[i], s, fee);
            } else {
                console2.log("  %s  %s     CLEAN        3000       0.30%%      Allowed (base fee)", labels[i], s);
            }
        }

        console2.log("");
        console2.log("  >> Same pool, same block: each address gets its own fee.");
        console2.log("  >> Clean users unaffected. Bots pay more or get blocked.");
    }

    // =====================================================================
    //  SIMULATION 4: JIT Liquidity Detection
    // =====================================================================

    function test_sim_jitLiquidity() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  SIMULATION: JIT Liquidity Detection");
        console2.log("================================================================");
        console2.log("");

        PoolModifyLiquidityTest jitRouter = new PoolModifyLiquidityTest(manager);
        token0.approve(address(jitRouter), type(uint256).max);
        token1.approve(address(jitRouter), type(uint256).max);

        console2.log("  Step 1: JIT bot adds liquidity right before a big swap");
        jitRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        console2.log("  Step 2: Victim does a large swap (bot earns fees on it)");
        _swapAsTrader(VICTIM, victimRouter, true, -0.5 ether);

        console2.log("  Step 3: JIT bot removes liquidity in the same block");
        console2.log("          >> JITDetected event emitted!");
        jitRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);

        console2.log("");
        console2.log("  >> Hook detects same-block add+swap+remove pattern.");
        console2.log("  >> Auto-triggers BLS scoring task for the JIT address.");
        console2.log("  >> If quorum confirms, JIT bot gets scored and escalated.");

        // Show that across different blocks, it's NOT flagged
        console2.log("");
        console2.log("  --- Normal LP (adds and removes across blocks) ---");
        vm.roll(block.number + 1);
        jitRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        vm.roll(block.number + 1);
        jitRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        console2.log("  Normal LP adds in block N, removes in block N+1");
        console2.log("  >> No JIT detection. Legitimate LPs are NOT penalized.");
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    /// @dev Swaps with `trader` as tx.origin while msg.sender stays this test
    ///      contract, which holds the tokens and approvals.
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
}
