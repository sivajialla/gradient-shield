// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ScoringOracle} from "./ScoringOracle.sol";

/// @title GradientShieldHook
/// @notice Uniswap v4 hook that prices swaps by the swapper's MEV risk score and
///         emits telemetry for an off-chain AVS (EigenLayer operator set) to consume.
/// @dev SCAFFOLD STUB — hook wiring, permissions, events, errors and the fee/detection
///      surface are laid out; the actual fee math and JIT/sandwich heuristics are
///      marked with TODOs.
///
/// Fee ladder (driven by {ScoringOracle} score):
///   score < SUSPICIOUS_THRESHOLD   → base dynamic fee
///   score < REJECT_THRESHOLD       → base fee × ESCALATION_MULTIPLIER (FeeEscalated)
///   score >= REJECT_THRESHOLD      → revert BotRejected
contract GradientShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    /// @notice Score at/above which swaps pay the escalated fee.
    uint16 public constant SUSPICIOUS_THRESHOLD = 40;

    /// @notice Score at/above which swaps are rejected outright.
    uint16 public constant REJECT_THRESHOLD = 80;

    /// @notice Multiplier applied to the base fee for suspicious swappers (3x).
    uint24 public constant ESCALATION_MULTIPLIER = 3;

    /// @notice Base LP fee in pips (1e6 = 100%). 3000 = 0.30%.
    /// @dev TODO: make per-pool configurable instead of a single constant.
    uint24 public constant BASE_FEE = 3000;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    ScoringOracle public immutable oracle;

    /// @notice Last swap block per (pool, swapper) — used by JIT/sandwich heuristics.
    /// @dev TODO: expand into whatever window state the detectors need
    ///      (e.g. last swap direction, last block, pending victim marker).
    mapping(PoolId => mapping(address => uint256)) internal _lastSwapBlock;

    // ---------------------------------------------------------------------
    // Events (indexed by the AVS operator node)
    // ---------------------------------------------------------------------

    /// @notice Emitted on every swap; the AVS indexes these to compute scores.
    event SwapTelemetry(
        PoolId indexed poolId,
        address indexed swapper,
        bool zeroForOne,
        int256 amountSpecified,
        uint16 score,
        uint24 feeCharged,
        uint256 blockNumber
    );

    /// @notice Emitted when the in-hook sandwich heuristic flags a swap.
    event SandwichDetected(PoolId indexed poolId, address indexed swapper, uint256 blockNumber);

    /// @notice Emitted when the JIT-liquidity heuristic flags an add/remove pattern.
    event JITDetected(PoolId indexed poolId, address indexed provider, uint256 blockNumber);

    /// @notice Emitted when a suspicious swapper is charged the escalated fee.
    event FeeEscalated(PoolId indexed poolId, address indexed swapper, uint24 baseFee, uint24 chargedFee);

    /// @notice Emitted when a swap is rejected for exceeding {REJECT_THRESHOLD}.
    event BotRejectedEvent(PoolId indexed poolId, address indexed swapper, uint16 score);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown in {_beforeSwap} when the swapper's score >= REJECT_THRESHOLD.
    error BotRejected(address swapper, uint16 score);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager _poolManager, ScoringOracle _oracle) BaseHook(_poolManager) {
        oracle = _oracle;
    }

    // ---------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // JIT detection entry point (TODO)
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // JIT detection exit point (TODO)
            afterRemoveLiquidity: false,
            beforeSwap: true, // fee logic + telemetry + sandwich detection
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // beforeSwap — the core of GradientShieldHook
    // ---------------------------------------------------------------------

    /// @dev Flow (TODO items are the real logic to fill in):
    ///   1. Read decayed score from the oracle for `sender`.
    ///   2. If score >= REJECT_THRESHOLD → emit BotRejectedEvent, revert BotRejected.
    ///   3. Run sandwich heuristic against {_lastSwapBlock} → maybe emit SandwichDetected.
    ///   4. Compute fee: escalate if score >= SUSPICIOUS_THRESHOLD (emit FeeEscalated).
    ///   5. Emit SwapTelemetry, record this block, and return the fee override.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata /*hookData*/ )
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint16 score = oracle.getScore(sender);

        // 2. Hard reject.
        if (score >= REJECT_THRESHOLD) {
            emit BotRejectedEvent(poolId, sender, score);
            revert BotRejected(sender, score);
        }

        // 3. Sandwich heuristic.
        // TODO: compare params.zeroForOne / block cadence against _lastSwapBlock and
        //       emit SandwichDetected when the back-run pattern is observed.

        // 4. Fee computation.
        uint24 fee = BASE_FEE;
        if (score >= SUSPICIOUS_THRESHOLD) {
            fee = BASE_FEE * ESCALATION_MULTIPLIER;
            emit FeeEscalated(poolId, sender, BASE_FEE, fee);
        }

        // 5. Telemetry + bookkeeping.
        emit SwapTelemetry(
            poolId, sender, params.zeroForOne, params.amountSpecified, score, fee, block.number
        );
        _lastSwapBlock[poolId][sender] = block.number;

        // Return the fee as a dynamic-fee override (2nd-highest bit set per v4 spec).
        // TODO: only valid if the pool was initialised with a dynamic fee. Guard or
        //       document that requirement in Deploy.s.sol / pool setup.
        uint24 overrideFee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    // ---------------------------------------------------------------------
    // JIT-liquidity detection hooks
    // ---------------------------------------------------------------------

    /// @dev TODO: record the add-liquidity block; if a remove-liquidity for the same
    ///      provider lands in the same block/swap window, emit JITDetected and
    ///      optionally feed it into the oracle scoring pipeline.
    function _beforeAddLiquidity(
        address, /*sender*/
        PoolKey calldata, /*key*/
        ModifyLiquidityParams calldata, /*params*/
        bytes calldata /*hookData*/
    ) internal override returns (bytes4) {
        // Passthrough for now.
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address, /*sender*/
        PoolKey calldata, /*key*/
        ModifyLiquidityParams calldata, /*params*/
        bytes calldata /*hookData*/
    ) internal override returns (bytes4) {
        // Passthrough for now.
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
