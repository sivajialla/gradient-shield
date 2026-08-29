// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
///         detects sandwich attacks and JIT liquidity patterns on-chain.
///
/// Fee ladder (driven by {ScoringOracle} score):
///   score < SUSPICIOUS_THRESHOLD   -> base dynamic fee
///   score < REJECT_THRESHOLD       -> base fee x ESCALATION_MULTIPLIER (FeeEscalated)
///   score >= REJECT_THRESHOLD      -> revert BotRejected
///
/// Sandwich detection: flags an address that swaps in both directions within
/// the same block on the same pool, with at least one intervening swap by a
/// different address (the victim).
///
/// JIT detection: flags an address that adds and removes liquidity in the
/// same block on the same pool.
contract GradientShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    uint16 public constant SUSPICIOUS_THRESHOLD = 40;
    uint16 public constant REJECT_THRESHOLD = 80;
    uint24 public constant ESCALATION_MULTIPLIER = 3;
    uint24 public constant BASE_FEE = 3000;

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------

    ScoringOracle public immutable oracle;

    /// @notice Tracks the first swap direction per (pool, swapper) in a given block.
    struct SwapRecord {
        uint256 blockNumber;
        bool zeroForOne;
    }

    mapping(PoolId => mapping(address => SwapRecord)) internal _firstSwap;

    /// @notice Per-pool swap counter within a block, used to confirm an
    ///         intervening victim swap between the front-run and back-run.
    struct BlockSwapCounter {
        uint256 blockNumber;
        uint256 count;
    }

    mapping(PoolId => BlockSwapCounter) internal _blockSwaps;

    /// @notice Tracks add-liquidity per (pool, provider) in a given block for JIT detection.
    struct LiquidityRecord {
        uint256 blockNumber;
    }

    mapping(PoolId => mapping(address => LiquidityRecord)) internal _liquidityAdds;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SwapTelemetry(
        PoolId indexed poolId,
        address indexed swapper,
        bool zeroForOne,
        int256 amountSpecified,
        uint16 score,
        uint24 feeCharged,
        uint256 blockNumber
    );

    event SandwichDetected(PoolId indexed poolId, address indexed swapper, uint256 blockNumber);
    event JITDetected(PoolId indexed poolId, address indexed provider, uint256 blockNumber);
    event FeeEscalated(PoolId indexed poolId, address indexed swapper, uint24 baseFee, uint24 chargedFee);
    event BotRejectedEvent(PoolId indexed poolId, address indexed swapper, uint16 score);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

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

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
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
    // beforeSwap
    // ---------------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        uint16 score = oracle.getScore(sender);

        // Hard reject.
        if (score >= REJECT_THRESHOLD) {
            emit BotRejectedEvent(poolId, sender, score);
            revert BotRejected(sender, score);
        }

        // Sandwich heuristic: same address, same pool, same block, opposite direction,
        // with at least one intervening swap (the victim).
        SwapRecord storage first = _firstSwap[poolId][sender];
        BlockSwapCounter storage counter = _blockSwaps[poolId];

        // Reset per-block swap counter if we're in a new block.
        if (counter.blockNumber != block.number) {
            counter.blockNumber = block.number;
            counter.count = 0;
        }

        if (first.blockNumber == block.number) {
            // Same address already swapped this block — check for back-run.
            if (first.zeroForOne != params.zeroForOne && counter.count >= 2) {
                // Opposite direction + at least one intervening swap = sandwich back-run.
                emit SandwichDetected(poolId, sender, block.number);
            }
        } else {
            // First swap by this address in this block — record direction.
            first.blockNumber = block.number;
            first.zeroForOne = params.zeroForOne;
        }

        counter.count++;

        // Fee computation.
        uint24 fee = BASE_FEE;
        if (score >= SUSPICIOUS_THRESHOLD) {
            fee = BASE_FEE * ESCALATION_MULTIPLIER;
            emit FeeEscalated(poolId, sender, BASE_FEE, fee);
        }

        // Telemetry.
        emit SwapTelemetry(poolId, sender, params.zeroForOne, params.amountSpecified, score, fee, block.number);

        uint24 overrideFee = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    // ---------------------------------------------------------------------
    // JIT-liquidity detection
    // ---------------------------------------------------------------------

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        _liquidityAdds[poolId][sender].blockNumber = block.number;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        if (_liquidityAdds[poolId][sender].blockNumber == block.number) {
            emit JITDetected(poolId, sender, block.number);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
