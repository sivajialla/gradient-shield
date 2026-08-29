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
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

contract HookBehaviorTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

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
            abi.encode(manager, oracle)
        );
        hook = new GradientShieldHook{salt: salt}(IPoolManager(manager), oracle);
        require(address(hook) == hookAddr, "hook address mismatch");

        deployMintAndApprove2Currencies();

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function test_permissionsFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeInitialize);
    }

    function test_baseFeeForCleanSwapper() public {
        PoolId poolId = key.toId();

        vm.expectEmit(true, true, false, false);
        emit GradientShieldHook.SwapTelemetry(poolId, address(swapRouter), true, -100, 0, 3000, block.number);

        swap(key, true, -100, ZERO_BYTES);
    }

    function test_escalatedFeeForSuspiciousSwapper() public {
        vm.prank(avs);
        oracle.setScore(address(swapRouter), 50);

        PoolId poolId = key.toId();

        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, address(swapRouter), 3000, 9000);

        swap(key, true, -100, ZERO_BYTES);
    }

    function test_rejectBotAboveThreshold() public {
        vm.prank(avs);
        oracle.setScore(address(swapRouter), 85);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(GradientShieldHook.BotRejected.selector, address(swapRouter), uint16(85)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -100, ZERO_BYTES);
    }

    function test_dynamicFeeOverrideApplied() public {
        swap(key, true, -100, ZERO_BYTES);
    }
}
