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

contract MEVAttackDefenseTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    PoolSwapTest internal botRouter;
    PoolSwapTest internal victimRouter;
    PoolModifyLiquidityTest internal jitLPRouter;

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

        botRouter = new PoolSwapTest(manager);
        victimRouter = new PoolSwapTest(manager);
        jitLPRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 token0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(currency1));
        token0.approve(address(botRouter), type(uint256).max);
        token1.approve(address(botRouter), type(uint256).max);
        token0.approve(address(victimRouter), type(uint256).max);
        token1.approve(address(victimRouter), type(uint256).max);
        token0.approve(address(jitLPRouter), type(uint256).max);
        token1.approve(address(jitLPRouter), type(uint256).max);

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    // ---------------------------------------------------------------------
    // Sandwich detection
    // ---------------------------------------------------------------------

    function test_sandwichPatternIsDetected() public {
        PoolId poolId = key.toId();

        _swapVia(botRouter, true, -10);
        _swapVia(victimRouter, true, -10);

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.SandwichDetected(poolId, tx.origin, block.number);
        _swapVia(botRouter, false, -10);
    }

    function test_noSandwichWithoutVictim() public {
        _swapVia(botRouter, true, -10);
        _swapVia(botRouter, false, -10);
    }

    function test_noSandwichAcrossBlocks() public {
        _swapVia(botRouter, true, -10);
        _swapVia(victimRouter, true, -10);

        vm.roll(block.number + 1);

        _swapVia(botRouter, false, -10);
    }

    function test_sandwichBotEscalation() public {
        PoolId poolId = key.toId();

        // 1. Bot sandwiches a victim (detected).
        _swapVia(botRouter, true, -10);
        _swapVia(victimRouter, true, -10);

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.SandwichDetected(poolId, tx.origin, block.number);
        _swapVia(botRouter, false, -10);

        // 2. AVS scores the bot at 60 (suspicious band).
        vm.prank(avs);
        oracle.setScore(tx.origin, 60);
        assertEq(oracle.getScore(tx.origin), 60);

        // 3. Bot's next swap pays 3x fee.
        vm.roll(block.number + 1);
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 9000);
        _swapVia(botRouter, true, -10);

        // 4. AVS escalates to 95 (reject band).
        vm.prank(avs);
        oracle.setScore(tx.origin, 95);

        // 5. Bot's next swap is rejected.
        vm.roll(block.number + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(GradientShieldHook.BotRejected.selector, tx.origin, uint16(95)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swapVia(botRouter, true, -10);
    }

    // ---------------------------------------------------------------------
    // JIT liquidity detection
    // ---------------------------------------------------------------------

    function test_jitLiquidityIsDetected() public {
        PoolId poolId = key.toId();

        jitLPRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        _swapVia(victimRouter, true, -10);

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.JITDetected(poolId, tx.origin, block.number);
        jitLPRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_noJITAcrossBlocks() public {
        jitLPRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.roll(block.number + 1);

        jitLPRouter.modifyLiquidity(key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _swapVia(PoolSwapTest router, bool zeroForOne, int256 amountSpecified) internal {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }
}
