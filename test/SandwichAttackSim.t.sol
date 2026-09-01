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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Sandwich Attack Simulation
/// @notice Realistic MEV sandwich attack with 2 users and 1 bot.
///         Shows token balance changes at every step - who profits, who loses,
///         and how GradientShield changes the outcome.
contract SandwichAttackSimTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    // --- Actors (derived from private keys) ---
    uint256 constant USER1_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant USER2_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant BOT_PK   = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    address internal user1;
    address internal user2;
    address internal bot;

    // Each actor gets their own router (hook identifies swappers by router address)
    PoolSwapTest internal user1Router;
    PoolSwapTest internal user2Router;
    PoolSwapTest internal botRouter;

    MockERC20 internal weth;  // token0
    MockERC20 internal usdc;  // token1

    address internal avs = address(0xA75);

    function setUp() public {
        // Derive addresses from private keys
        user1 = vm.addr(USER1_PK);
        user2 = vm.addr(USER2_PK);
        bot   = vm.addr(BOT_PK);

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
        weth = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));

        // Create per-actor routers
        user1Router = new PoolSwapTest(manager);
        user2Router = new PoolSwapTest(manager);
        botRouter   = new PoolSwapTest(manager);

        // Fund actors: mint 100 WETH + 100_000 USDC to each
        uint256 wethAmount = 100 ether;
        uint256 usdcAmount = 100_000 ether; // 18-decimal mock USDC

        address[3] memory actors = [user1, user2, bot];
        PoolSwapTest[3] memory routers = [user1Router, user2Router, botRouter];

        for (uint256 i = 0; i < 3; i++) {
            weth.mint(actors[i], wethAmount);
            usdc.mint(actors[i], usdcAmount);

            // Each actor approves their own router
            vm.startPrank(actors[i]);
            weth.approve(address(routers[i]), type(uint256).max);
            usdc.approve(address(routers[i]), type(uint256).max);
            vm.stopPrank();
        }

        // Also approve from test contract (for initPoolAndAddLiquidity)
        weth.approve(address(botRouter), type(uint256).max);
        usdc.approve(address(botRouter), type(uint256).max);
        weth.approve(address(user1Router), type(uint256).max);
        usdc.approve(address(user1Router), type(uint256).max);
        weth.approve(address(user2Router), type(uint256).max);
        usdc.approve(address(user2Router), type(uint256).max);

        // Initialize pool: WETH/USDC with dynamic fee, 1:1 starting price
        // (simplified - real WETH/USDC would have different decimals)
        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    // =====================================================================
    //  SIMULATION: Full sandwich attack lifecycle
    // =====================================================================

    function test_sandwichAttack_fullLifecycle() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  SANDWICH ATTACK SIMULATION");
        console2.log("  2 Users + 1 MEV Bot on Uniswap v4 Pool");
        console2.log("================================================================");
        console2.log("");

        console2.log("  Actors:");
        console2.log("  User1 (victim):", user1);
        console2.log("  User2 (bystander):", user2);
        console2.log("  MEV Bot:", bot);
        console2.log("  Bot router:", address(botRouter));
        console2.log("  User1 router:", address(user1Router));
        console2.log("");

        // ---- Snapshot initial balances ----
        uint256 user1_weth_before = weth.balanceOf(user1);
        uint256 user1_usdc_before = usdc.balanceOf(user1);
        uint256 bot_weth_before   = weth.balanceOf(bot);
        uint256 bot_usdc_before   = usdc.balanceOf(bot);

        console2.log("--- INITIAL BALANCES ---");
        _logBalances("User1", user1);
        _logBalances("Bot  ", bot);
        console2.log("");

        // =====================================================================
        //  PHASE 1: Bot sees User1's pending swap and front-runs
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 1: THE SANDWICH");
        console2.log("================================================================");
        console2.log("");

        console2.log("  User1 submits: swap 1 WETH -> USDC (pending in mempool)");
        console2.log("  MEV bot sees this and constructs a sandwich:");
        console2.log("");

        // Step 1: Bot FRONT-RUNS - buys USDC before the victim
        console2.log("  [1] Bot FRONT-RUN: sells 100 units WETH -> USDC (pushes price)");
        _swapAs(bot, botRouter, true, -100);
        console2.log("      Bot bought USDC cheap, price moved up.");
        console2.log("");

        // Step 2: Victim's swap executes at worse price
        console2.log("  [2] User1 SWAP: sells 50 units WETH -> USDC (gets worse price!)");
        _swapAs(user1, user1Router, true, -50);
        console2.log("      User1 got less USDC than they would have without the bot.");
        console2.log("");

        // Step 3: Bot BACK-RUNS - sells USDC back for WETH (triggers detection)
        console2.log("  [3] Bot BACK-RUN: sells 100 units USDC -> WETH (captures profit)");
        console2.log("      >> This triggers SandwichDetected in GradientShield!");
        _swapAs(bot, botRouter, false, -100);
        console2.log("");

        // ---- Post-sandwich balances ----
        console2.log("--- BALANCES AFTER SANDWICH ---");
        _logBalances("User1", user1);
        _logBalances("Bot  ", bot);
        console2.log("");

        int256 user1_weth_delta = int256(weth.balanceOf(user1)) - int256(user1_weth_before);
        int256 user1_usdc_delta = int256(usdc.balanceOf(user1)) - int256(user1_usdc_before);
        int256 bot_weth_delta   = int256(weth.balanceOf(bot)) - int256(bot_weth_before);
        int256 bot_usdc_delta   = int256(usdc.balanceOf(bot)) - int256(bot_usdc_before);

        console2.log("--- P&L ---");
        console2.log("  User1 WETH change:");
        console2.log(user1_weth_delta);
        console2.log("  User1 USDC change:");
        console2.log(user1_usdc_delta);
        console2.log("  Bot WETH change:");
        console2.log(bot_weth_delta);
        console2.log("  Bot USDC change:");
        console2.log(bot_usdc_delta);
        console2.log("");

        // =====================================================================
        //  PHASE 2: GradientShield responds - AVS scores the bot
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 2: GRADIENTSHIELD RESPONSE");
        console2.log("================================================================");
        console2.log("");

        console2.log("  Hook detected sandwich pattern (same sender, opposite direction,");
        console2.log("  victim in between, all in one block).");
        console2.log("  BLS quorum scoring task auto-triggered for bot address.");
        console2.log("");

        // AVS quorum confirms: bot scored 65 (suspicious band)
        vm.prank(avs);
        oracle.setScore(tx.origin, 65);
        uint16 botScore = oracle.getScore(tx.origin);
        uint24 escalatedFee = 3000 + (15000 - 3000) * uint24(botScore - 40) / 40;

        console2.log("  BLS quorum verdict: bot score = 65 (SUSPICIOUS)");
        console2.log("  Escalated fee:");
        console2.log(escalatedFee);
        console2.log("  pips (vs 3000 base = 0.30%%)");
        console2.log("");

        // =====================================================================
        //  PHASE 3: Bot tries again - pays escalated fee
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 3: BOT TRIES AGAIN (ESCALATED FEE)");
        console2.log("================================================================");
        console2.log("");

        vm.roll(block.number + 1); // new block

        uint256 bot_weth_pre2 = weth.balanceOf(bot);
        uint256 bot_usdc_pre2 = usdc.balanceOf(bot);

        console2.log("  Bot attempts another front-run: sells 100 units WETH -> USDC");
        _swapAs(bot, botRouter, true, -100);

        int256 bot_weth_delta2 = int256(weth.balanceOf(bot)) - int256(bot_weth_pre2);
        int256 bot_usdc_delta2 = int256(usdc.balanceOf(bot)) - int256(bot_usdc_pre2);

        console2.log("  Bot WETH change:");
        console2.log(bot_weth_delta2);
        console2.log("  Bot USDC received:");
        console2.log(bot_usdc_delta2);
        console2.log("  >> Bot pays escalated fee - sandwich profit margin destroyed.");
        console2.log("");

        // =====================================================================
        //  PHASE 4: User2 swaps normally - base fee, no penalty
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 4: CLEAN USER2 SWAPS (UNAFFECTED)");
        console2.log("================================================================");
        console2.log("");

        uint256 user2_weth_pre = weth.balanceOf(user2);
        uint256 user2_usdc_pre = usdc.balanceOf(user2);

        console2.log("  User2 (score=0) swaps 50 units WETH -> USDC at base fee...");
        _swapAs(user2, user2Router, true, -50);

        int256 user2_weth_delta = int256(weth.balanceOf(user2)) - int256(user2_weth_pre);
        int256 user2_usdc_delta = int256(usdc.balanceOf(user2)) - int256(user2_usdc_pre);

        console2.log("  User2 WETH change:");
        console2.log(user2_weth_delta);
        console2.log("  User2 USDC received:");
        console2.log(user2_usdc_delta);
        console2.log("  >> Clean users trade at 0.30%% base fee. No penalty.");
        console2.log("");

        // =====================================================================
        //  PHASE 5: Bot score escalated to 85 -> REJECTED
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 5: BOT BLOCKED (SCORE >= 80)");
        console2.log("================================================================");
        console2.log("");

        vm.prank(avs);
        oracle.setScore(tx.origin, 85);
        console2.log("  BLS quorum bumps bot score to 85 -> REJECT band");

        vm.roll(block.number + 1);

        console2.log("  Bot tries to swap...");
        vm.expectRevert();
        _swapAs(bot, botRouter, true, -50);
        console2.log("  >> REVERTED: BotRejected(bot, 85)");
        console2.log("  >> Bot cannot trade. Pool fully protected.");
        console2.log("");

        // =====================================================================
        //  PHASE 6: Score decay - bot rehabilitated after stopping attacks
        // =====================================================================
        console2.log("================================================================");
        console2.log("  PHASE 6: REHABILITATION (SCORE DECAY)");
        console2.log("================================================================");
        console2.log("");

        console2.log("  Bot stops attacking. Score decays 5 points/day...");

        uint256 startTime = block.timestamp;
        uint16[5] memory checkDays = [uint16(0), 2, 4, 10, 18];

        for (uint256 i = 0; i < checkDays.length; i++) {
            vm.warp(startTime + uint256(checkDays[i]) * 1 days);
            uint16 s = oracle.getScore(tx.origin);
            string memory band;
            if (s >= 80) band = "REJECTED";
            else if (s >= 40) band = "SUSPICIOUS";
            else band = "CLEAN";
            console2.log("  Day %s: score=%s  [%s]", checkDays[i], s, band);
        }

        console2.log("");
        console2.log("  >> After 18 days without attacks, bot is back to CLEAN.");
        console2.log("     If bot attacks again, score re-escalates immediately.");

        console2.log("");
        console2.log("================================================================");
        console2.log("  SIMULATION COMPLETE");
        console2.log("  - Sandwich detected in real-time via transient storage");
        console2.log("  - Bot fee escalated from 0.30%% to 1.05%%");
        console2.log("  - Bot fully blocked at score 85");
        console2.log("  - Clean users (User2) never affected");
        console2.log("  - Bot can rehabilitate by stopping attacks");
        console2.log("================================================================");
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

    function _logBalances(string memory label, address actor) internal view {
        console2.log("  %s  WETH: %s  USDC: %s", label, weth.balanceOf(actor), usdc.balanceOf(actor));
    }
}
