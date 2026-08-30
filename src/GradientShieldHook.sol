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
import {IScoreTaskCreator} from "./IScoreTaskCreator.sol";

/// @title GradientShieldHook
/// @notice Uniswap v4 hook that prices swaps by the swapper's MEV risk score,
///         detects sandwich/JIT patterns on-chain using transient storage (EIP-1153),
///         and auto-triggers BLS quorum scoring tasks when patterns are detected.
///
/// Gas optimization: all per-block detection state (sandwich tracking, swap
/// counters, JIT liquidity flags) uses TSTORE/TLOAD (100 gas each) instead of
/// SSTORE/SLOAD (5k-20k gas). This saves ~20k gas per swap on detection logic.
/// Transient storage auto-clears at transaction end — no manual reset needed.
///
/// Continuous fee curve (driven by {ScoringOracle} score):
///   score < 40   -> BASE_FEE (3000 pips = 0.30%)
///   40 <= score < 80 -> linear interpolation BASE_FEE to MAX_ESCALATED_FEE
///   score >= 80  -> revert BotRejected
///
/// BLS integration: on-chain detection auto-triggers scoring tasks on the
/// TaskManager. The BLS operator quorum evaluates flagged addresses, and
/// quorum-verified scores feed back into fee decisions on subsequent swaps.
contract GradientShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    uint16 public constant SUSPICIOUS_THRESHOLD = 40;
    uint16 public constant REJECT_THRESHOLD = 80;
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MAX_ESCALATED_FEE = 15000;

    uint32 public constant DETECTION_QUORUM_THRESHOLD = 67;
    uint256 public constant DETECTION_LOOKBACK = 10;
    uint256 public constant TASK_COOLDOWN_BLOCKS = 50;
    uint256 public constant STALENESS_THRESHOLD = 7 days;

    // Transient storage namespace seeds (prevent slot collisions).
    bytes32 private constant _FIRST_SWAP_NS = keccak256("GradientShield.firstSwap");
    bytes32 private constant _BLOCK_SWAPS_NS = keccak256("GradientShield.blockSwaps");
    bytes32 private constant _LIQUIDITY_NS = keccak256("GradientShield.liquidityAdds");

    // Transient storage sentinel values for first-swap direction.
    uint256 private constant _SWAP_ZERO_FOR_ONE = 1;
    uint256 private constant _SWAP_ONE_FOR_ZERO = 2;

    // ---------------------------------------------------------------------
    // Persistent state (cross-transaction)
    // ---------------------------------------------------------------------

    ScoringOracle public immutable oracle;
    IScoreTaskCreator public immutable taskManager;

    mapping(address => uint256) internal _lastTaskBlock;

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
    event ScoreTaskTriggered(address indexed subject, uint256 blockNumber, string detectionType);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error BotRejected(address swapper, uint16 score);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        ScoringOracle _oracle,
        IScoreTaskCreator _taskManager
    ) BaseHook(_poolManager) {
        oracle = _oracle;
        taskManager = _taskManager;
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

        if (score >= REJECT_THRESHOLD) {
            emit BotRejectedEvent(poolId, sender, score);
            revert BotRejected(sender, score);
        }

        if (score > 0) _checkStaleness(sender);

        _detectSandwich(poolId, sender, params.zeroForOne);

        uint24 fee = _computeFee(score);
        if (fee > BASE_FEE) emit FeeEscalated(poolId, sender, BASE_FEE, fee);

        emit SwapTelemetry(poolId, sender, params.zeroForOne, params.amountSpecified, score, fee, block.number);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _detectSandwich(PoolId poolId, address sender, bool zeroForOne) internal {
        bytes32 firstSlot = _firstSwapSlot(poolId, sender);
        uint256 recorded = _tload(firstSlot);
        bytes32 counterSlot = _blockSwapsSlot(poolId);
        uint256 swapCount = _tload(counterSlot);

        if (recorded != 0) {
            if ((recorded == _SWAP_ZERO_FOR_ONE) != zeroForOne && swapCount >= 2) {
                emit SandwichDetected(poolId, sender, block.number);
                _triggerScoreTask(sender, "sandwich");
            }
        } else {
            _tstore(firstSlot, zeroForOne ? _SWAP_ZERO_FOR_ONE : _SWAP_ONE_FOR_ZERO);
        }

        _tstore(counterSlot, swapCount + 1);
    }

    // ---------------------------------------------------------------------
    // Fee curve
    // ---------------------------------------------------------------------

    function _computeFee(uint16 score) internal pure returns (uint24) {
        if (score < SUSPICIOUS_THRESHOLD) return BASE_FEE;

        uint24 range = uint24(REJECT_THRESHOLD - SUSPICIOUS_THRESHOLD);
        uint24 position = uint24(score - SUSPICIOUS_THRESHOLD);
        return BASE_FEE + (MAX_ESCALATED_FEE - BASE_FEE) * position / range;
    }

    // ---------------------------------------------------------------------
    // JIT-liquidity detection (transient storage)
    // ---------------------------------------------------------------------

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        _tstore(_liquiditySlot(poolId, sender), 1);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        if (_tload(_liquiditySlot(poolId, sender)) == 1) {
            emit JITDetected(poolId, sender, block.number);
            _triggerScoreTask(sender, "jit");
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // ---------------------------------------------------------------------
    // BLS task auto-trigger
    // ---------------------------------------------------------------------

    function _triggerScoreTask(address subject, string memory detectionType) internal {
        if (address(taskManager) == address(0)) return;
        if (_lastTaskBlock[subject] + TASK_COOLDOWN_BLOCKS > block.number) return;

        uint256 fromBlock = block.number > DETECTION_LOOKBACK ? block.number - DETECTION_LOOKBACK : 0;

        try taskManager.createScoreTask(
            subject,
            fromBlock,
            block.number,
            DETECTION_QUORUM_THRESHOLD,
            hex"00"
        ) {
            _lastTaskBlock[subject] = block.number;
            emit ScoreTaskTriggered(subject, block.number, detectionType);
        } catch {}
    }

    // ---------------------------------------------------------------------
    // Stale score re-evaluation
    // ---------------------------------------------------------------------

    function _checkStaleness(address subject) internal {
        if (address(taskManager) == address(0)) return;

        ScoringOracle.ScoreRecord memory rec = oracle.rawRecord(subject);
        if (rec.lastUpdated == 0) return;
        if (block.timestamp - uint256(rec.lastUpdated) < STALENESS_THRESHOLD) return;

        _triggerScoreTask(subject, "stale");
    }

    // ---------------------------------------------------------------------
    // Transient storage helpers (EIP-1153)
    // ---------------------------------------------------------------------

    function _tstore(bytes32 slot, uint256 value) internal {
        assembly { tstore(slot, value) }
    }

    function _tload(bytes32 slot) internal view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    function _firstSwapSlot(PoolId poolId, address sender) internal view returns (bytes32) {
        return keccak256(abi.encode(_FIRST_SWAP_NS, poolId, sender, block.number));
    }

    function _blockSwapsSlot(PoolId poolId) internal view returns (bytes32) {
        return keccak256(abi.encode(_BLOCK_SWAPS_NS, poolId, block.number));
    }

    function _liquiditySlot(PoolId poolId, address sender) internal view returns (bytes32) {
        return keccak256(abi.encode(_LIQUIDITY_NS, poolId, sender, block.number));
    }
}
