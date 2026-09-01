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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Cross-Transaction Detection
/// @notice Regression guard for the hook's per-block detection state.
///
/// The hook originally kept this state in transient storage (EIP-1153). That
/// looked correct in Foundry — a test function is a single transaction, so
/// TSTORE values survive from one swap call to the next — but it is wrong on a
/// live chain: transient storage is discarded at the end of every TRANSACTION,
/// and a real sandwich is three separate transactions (front-run, victim,
/// back-run). Nothing survived from the front-run to the back-run, so no
/// sandwich was ever detected in production.
///
/// The state now lives in persistent storage, stamped with the block that wrote
/// it so it still resets every block. These tests pin that down:
///
///   • {test_detectionState_livesInPersistentStorage} reads the raw slot with
///     vm.load, which can only see persistent storage. If someone switches back
///     to TSTORE this fails immediately.
///   • The remaining tests pin the block-scoping semantics that replace
///     transient storage's automatic clearing.
///
/// True multi-transaction behaviour is exercised by the anvil demo
/// (`make deploy-local && make attack`), which mines three separate
/// transactions into one block.
contract CrossTransactionDetectionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;
    PoolSwapTest internal botRouter;
    PoolSwapTest internal victimRouter;

    address internal bot = address(0xB07);
    address internal victim = address(0xA01);

    /// @dev Storage slot of GradientShieldHook._blockState.
    ///      Verified with `forge inspect GradientShieldHook storage-layout`.
    uint256 internal constant BLOCK_STATE_SLOT = 2;

    bytes32 internal constant SENDER_IMPACT_NS = keccak256("GradientShield.senderImpact");

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
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));

        botRouter = new PoolSwapTest(manager);
        victimRouter = new PoolSwapTest(manager);

        address[2] memory actors = [bot, victim];
        PoolSwapTest[2] memory routers = [botRouter, victimRouter];
        for (uint256 i = 0; i < 2; i++) {
            t0.mint(actors[i], 1000 ether);
            t1.mint(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            t0.approve(address(routers[i]), type(uint256).max);
            t1.approve(address(routers[i]), type(uint256).max);
            vm.stopPrank();
        }

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
        t0.mint(address(this), 10_000 ether);
        t1.mint(address(this), 10_000 ether);
        t0.approve(address(modifyLiquidityRouter), type(uint256).max);
        t1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // =====================================================================

    /// The core regression: detection state must be readable from persistent
    /// storage. vm.load cannot see transient storage, so a TSTORE-based hook
    /// would return zero here and fail.
    function test_detectionState_livesInPersistentStorage() public {
        _swapAs(bot, botRouter, true, -3 ether);

        bytes32 slot = _senderImpactSlot(key.toId(), bot);
        uint256 packed = uint256(vm.load(address(hook), slot));

        assertTrue(packed != 0, "detection state must survive in persistent storage");

        uint256 storedBlock = packed >> 192;
        uint256 payload = packed & ((1 << 192) - 1);

        assertEq(storedBlock, block.number, "entry is stamped with the writing block");
        assertEq(payload, 3 ether, "payload is the trader's cumulative volume");
    }

    /// A stale entry from an earlier block must read as empty — this is what
    /// replaces transient storage's automatic end-of-transaction clearing.
    function test_blockStamp_makesStaleEntriesReadAsEmpty() public {
        _swapAs(bot, botRouter, true, -4 ether);

        bytes32 slot = _senderImpactSlot(key.toId(), bot);
        uint256 blockN = uint256(vm.load(address(hook), slot)) >> 192;
        assertEq(blockN, block.number);

        vm.roll(block.number + 1);

        // The slot is still physically populated with the old block's data...
        assertTrue(uint256(vm.load(address(hook), slot)) != 0, "slot is not wiped");

        // ...but the hook ignores it, so the sender starts the new block clean:
        // 4 ether again stays under the 5 ether threshold and pays base fee.
        vm.recordLogs();
        _swapAs(bot, botRouter, true, -4 ether);
        assertFalse(_sawEvent(vm.getRecordedLogs(), "SenderImpactCapped(bytes32,address,uint256,uint24)"));
    }

    /// Volume accumulates within a block across separate swap calls.
    function test_volumeAccumulates_withinOneBlock() public {
        _swapAs(bot, botRouter, true, -3 ether);

        vm.recordLogs();
        _swapAs(bot, botRouter, true, -3 ether);

        assertTrue(
            _sawEvent(vm.getRecordedLogs(), "SenderImpactCapped(bytes32,address,uint256,uint24)"),
            "3 + 3 ether must cross the 5 ether threshold"
        );
    }

    /// The full sandwich shape still fires with the block-scoped state.
    function test_sandwichStillDetected() public {
        _swapAs(bot, botRouter, true, -1 ether);
        _swapAs(victim, victimRouter, true, -1 ether);

        vm.recordLogs();
        _swapAs(bot, botRouter, false, -1 ether);

        assertTrue(
            _sawEvent(vm.getRecordedLogs(), "SandwichDetected(bytes32,address,uint256)"),
            "buy -> victim -> sell must be detected"
        );
    }

    /// A first-time offender must be scoreable immediately. The task cooldown
    /// previously suppressed every first offence while block.number was below
    /// TASK_COOLDOWN_BLOCKS, because a never-scored address has
    /// _lastTaskBlock == 0.
    function test_firstOffence_isScoreableAtLowBlockNumbers() public {
        // Redeploy at block 5 with a task manager wired in, so the cooldown
        // arithmetic (0 + 50 > 5) would trip if the zero case were unhandled.
        vm.roll(5);

        RecordingTaskCreator creator = new RecordingTaskCreator();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address addr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(creator)), address(0))
        );
        GradientShieldHook freshHook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(creator)), address(0)
        );
        require(address(freshHook) == addr, "hook address mismatch");

        (PoolKey memory freshKey,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(freshHook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        // initPoolAndAddLiquidity seeds only ~1e18 units, which a 6 ether swap
        // would push straight into the price limit.
        modifyLiquidityRouter.modifyLiquidity(
            freshKey,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 100_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        // A single swap past the volume threshold is enough to flag the sender.
        vm.prank(bot);
        botRouter.swap(
            freshKey,
            SwapParams({zeroForOne: true, amountSpecified: -6 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        // The flag is consumed on the sender's next swap, which creates the task.
        vm.prank(bot);
        botRouter.swap(
            freshKey,
            SwapParams({zeroForOne: true, amountSpecified: -0.1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertGt(creator.calls(), 0, "first offence must create a scoring task at low block numbers");
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _senderImpactSlot(PoolId poolId, address sender) internal pure returns (bytes32) {
        bytes32 key_ = keccak256(abi.encode(SENDER_IMPACT_NS, poolId, sender));
        return keccak256(abi.encode(key_, BLOCK_STATE_SLOT));
    }

    function _sawEvent(Vm.Log[] memory logs, string memory sig) internal pure returns (bool) {
        bytes32 topic = keccak256(bytes(sig));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _swapAs(address actor, PoolSwapTest router, bool zeroForOne, int256 amount) internal {
        // Two-arg prank sets tx.origin too, so each actor is a distinct trader.
        vm.prank(actor, actor);
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

/// @dev Counts createScoreTask calls so a test can assert a task was triggered.
contract RecordingTaskCreator is IScoreTaskCreator {
    uint256 public calls;

    function createScoreTask(address, uint256, uint256, uint32, bytes calldata) external {
        calls++;
    }

    function taskNumber() external view returns (uint32) {
        return uint32(calls);
    }

    function latestTaskForSubject(address) external pure returns (uint32) {
        return 0;
    }
}
