// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import {ScoringOracle} from "./ScoringOracle.sol";
import {IScoreTaskCreator} from "./IScoreTaskCreator.sol";
import {ITrustedRouter} from "./ITrustedRouter.sol";

/// @title GradientShieldHook
/// @notice Uniswap v4 hook that prices swaps by the swapper's MEV risk score,
///         detects sandwich/JIT patterns on-chain, and auto-triggers BLS quorum
///         scoring tasks when patterns are detected.
///
/// Detection state (sandwich direction, swap counters, JIT liquidity flags,
/// cumulative volumes) is block-scoped: each entry is stamped with the block
/// that wrote it, so it reads back as empty in the next block and needs no
/// explicit reset. See {_bload} for why this uses persistent storage rather
/// than transient storage (EIP-1153) — in short, a sandwich spans three
/// separate transactions, and transient state does not survive between them.
///
/// Continuous fee curve (driven by {ScoringOracle} score):
///   score < 40   -> BASE_FEE (3000 pips = 0.30%)
///   40 <= score < 80 -> linear interpolation BASE_FEE to MAX_ESCALATED_FEE
///   score >= 80  -> revert BotRejected
///
/// BLS integration: on-chain detection auto-triggers scoring tasks on the
/// TaskManager. The BLS operator quorum evaluates flagged addresses, and
/// quorum-verified scores feed back into fee decisions on subsequent swaps.
///
/// Identity: every score, fee, detection and volume budget is attributed to the
/// *trader*, resolved by {_resolveTrader} — not to the router that v4 hands the
/// hook as `sender`. Without this, everyone behind a shared router shares one
/// reputation.
///
/// hookData attestation (optional): swappers can pass a signed score
/// attestation via hookData to skip the on-chain oracle call. The attestor
/// signs (sender, score, expiry, chainId, hookAddress) off-chain; the hook
/// verifies the ECDSA signature and uses the attested score. Gas cost is
/// comparable to the oracle path — the value is in avoiding the external
/// call latency. Falls back to on-chain oracle when hookData is empty, the
/// attestor is not set, the signature is invalid, or the attestation expired.
contract GradientShieldHook is BaseHook, IUnlockCallback {
    // BaseHook provides onlyPoolManager modifier via ImmutableState.
    // IUnlockCallback provides the unlockCallback interface for multi-hop routing.
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

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

    // Price impact guard: cumulative abs(amountSpecified) per pool per block.
    // When total volume exceeds this, subsequent swaps pay escalated fees,
    // making the back-run leg of a sandwich unprofitable.
    uint256 public constant POOL_IMPACT_THRESHOLD = 10 ether;

    // Per-sender volume threshold: when a single sender's cumulative volume
    // in one pool in one block exceeds this, a progressive penalty fee applies.
    // No revert — the system is fully permissionless.
    uint256 public constant SENDER_VOLUME_THRESHOLD = 5 ether;

    // Progressive fee tiers (pips). As sender volume grows within a block,
    // the fee escalates, making sandwich back-runs increasingly unprofitable.
    //   0 – SENDER_VOLUME_THRESHOLD:   base fee (3000 pips = 0.30%)
    //   1x – 2x threshold:             15000 pips (1.50%)
    //   2x – 4x threshold:             30000 pips (3.00%)
    //   > 4x threshold:                50000 pips (5.00%)
    uint24 public constant IMPACT_FEE_TIER1 = 15000;
    uint24 public constant IMPACT_FEE_TIER2 = 30000;
    uint24 public constant IMPACT_FEE_TIER3 = 50000;

    // Per-block detection-state namespace seeds (prevent slot collisions).
    bytes32 private constant _FIRST_SWAP_NS = keccak256("GradientShield.firstSwap");
    bytes32 private constant _BLOCK_SWAPS_NS = keccak256("GradientShield.blockSwaps");
    bytes32 private constant _LIQUIDITY_NS = keccak256("GradientShield.liquidityAdds");
    bytes32 private constant _POOL_IMPACT_NS = keccak256("GradientShield.poolImpact");
    bytes32 private constant _SENDER_IMPACT_NS = keccak256("GradientShield.senderImpact");

    // Sentinel values for first-swap direction.
    uint256 private constant _SWAP_ZERO_FOR_ONE = 1;
    uint256 private constant _SWAP_ONE_FOR_ZERO = 2;

    // Block-scoped state packs the writing block into the high 64 bits so a
    // stale entry from an earlier block reads back as empty. See {_bload}.
    uint256 private constant _BLOCK_SHIFT = 192;
    uint256 private constant _PAYLOAD_MASK = (1 << 192) - 1;

    // ---------------------------------------------------------------------
    // Persistent state (cross-transaction)
    // ---------------------------------------------------------------------

    ScoringOracle public immutable oracle;
    IScoreTaskCreator public immutable taskManager;
    address public immutable attestor;

    mapping(address => uint256) internal _lastTaskBlock;
    mapping(address => bool) internal _pendingScoreFlag;

    /// @dev Per-block detection state (sandwich direction, swap counters, JIT
    ///      flags, cumulative volumes). Entries are stamped with the block that
    ///      wrote them, so a read from a later block sees zero without any
    ///      explicit reset.
    mapping(bytes32 => uint256) internal _blockState;

    /// @notice Routers trusted to report the true originator of a swap.
    /// @dev The allow-list every identity claim is gated on — see
    ///      {_resolveTrader}. Listing a router asserts that it reports the
    ///      originator honestly, either via {ITrustedRouter.getMsgSender} or by
    ///      writing the address into `hookData` itself. A router that merely
    ///      forwards caller-supplied bytes must never be listed, since the
    ///      caller would then choose their own identity.
    mapping(address => bool) public trustedRouters;

    /// @notice Can only mark routers as originator-forwarding. Deliberately
    ///         narrow: the owner cannot set scores, change fees, reject
    ///         addresses, or move funds.
    address public owner;

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
    event PoolImpactGuard(PoolId indexed poolId, address indexed sender, uint256 cumulativeImpact, uint24 penaltyFee);
    event SenderImpactCapped(PoolId indexed poolId, address indexed sender, uint256 senderImpact, uint24 penaltyFee);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error BotRejected(address swapper, uint16 score);
    error DeadlineExpired();
    error NotOwner();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        ScoringOracle _oracle,
        IScoreTaskCreator _taskManager,
        address _attestor
    ) BaseHook(_poolManager) {
        oracle = _oracle;
        taskManager = _taskManager;
        attestor = _attestor;
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Trusted router registry
    // ---------------------------------------------------------------------

    event TrustedRouterSet(address indexed router, bool trusted);
    event OwnershipTransferred(address indexed from, address indexed to);

    /// @notice Mark a router as one that honestly reports the swap originator.
    /// @dev Only vet routers whose source you have read. A listed router can
    ///      name any address as the trader, so a malicious one could launder
    ///      its own reputation or frame an innocent address.
    function setTrustedRouter(address router, bool trusted) external {
        if (msg.sender != owner) revert NotOwner();
        if (router == address(0)) revert ZeroAddress();
        trustedRouters[router] = trusted;
        emit TrustedRouterSet(router, trusted);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Renounce the ability to change the trusted-router set, freezing
    ///         identity resolution to `tx.origin` plus whatever is already set.
    function renounceOwnership() external {
        if (msg.sender != owner) revert NotOwner();
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ---------------------------------------------------------------------
    // Multi-hop router (unlockCallback settlement)
    // ---------------------------------------------------------------------

    struct SwapHop {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    struct MultiHopParams {
        SwapHop[] hops;
        Currency[] currencies;
        address sender;
        uint256 deadline;
    }

    event MultiHopExecuted(address indexed sender, uint256 hops);

    /// @notice Execute multiple swaps in a single unlock context. Intermediate
    ///         token balances cancel out inside the PoolManager's internal
    ///         accounting — only the net input and output are settled via
    ///         ERC6909 claim tokens (burn for debits, mint for credits).
    ///         No ERC-20 transferFrom calls, no approvals to the hook.
    /// @dev    Caller must hold sufficient ERC6909 claim balances on the
    ///         PoolManager for each input currency (obtained via
    ///         poolManager.settle + poolManager.mint beforehand) and must
    ///         have approved this hook as an ERC6909 operator on the
    ///         PoolManager (poolManager.setOperator(hook, true)).
    /// @param hops       Ordered swap legs (A→B, B→C, …).
    /// @param currencies All unique currencies touched by the hops (used for
    ///                   settlement after the swaps execute).
    /// @param deadline   Revert if block.timestamp exceeds this.
    function multiHopSwap(
        SwapHop[] calldata hops,
        Currency[] calldata currencies,
        uint256 deadline
    ) external {
        if (block.timestamp > deadline) revert DeadlineExpired();

        bytes memory data = abi.encode(MultiHopParams({
            hops: hops,
            currencies: currencies,
            sender: msg.sender,
            deadline: deadline
        }));
        poolManager.unlock(data);

        emit MultiHopExecuted(msg.sender, hops.length);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        MultiHopParams memory params = abi.decode(data, (MultiHopParams));

        for (uint256 i = 0; i < params.hops.length; i++) {
            poolManager.swap(params.hops[i].key, SwapParams({
                zeroForOne: params.hops[i].zeroForOne,
                amountSpecified: params.hops[i].amountSpecified,
                sqrtPriceLimitX96: params.hops[i].sqrtPriceLimitX96
            }), params.hops[i].hookData);
        }

        for (uint256 i = 0; i < params.currencies.length; i++) {
            _settleCurrencyERC6909(params.currencies[i], params.sender);
        }

        return "";
    }

    /// @dev Settles a currency delta using ERC6909 claims on the PoolManager.
    ///      Negative delta (hook owes tokens) → burn claims from sender.
    ///      Positive delta (hook is owed tokens) → mint claims to sender.
    ///      No ERC-20 transfers — purely internal PoolManager accounting.
    function _settleCurrencyERC6909(Currency currency, address sender) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);

        if (delta < 0) {
            uint256 amount = uint256(-delta);
            poolManager.burn(sender, currency.toId(), amount);
        } else if (delta > 0) {
            poolManager.mint(sender, currency.toId(), uint256(delta));
        }
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

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        // `sender` is whoever called poolManager.swap() — a router, not the
        // person trading. Everything below is attributed to the trader.
        address trader = _resolveTrader(sender, hookData);

        uint16 score = _resolveScore(trader, hookData);

        if (score >= REJECT_THRESHOLD) {
            emit BotRejectedEvent(poolId, trader, score);
            revert BotRejected(trader, score);
        }

        if (score > 0) _checkStaleness(trader);

        _detectSandwich(poolId, trader, params.zeroForOne);

        uint24 fee = _computeFee(score);

        // --- Price impact guards (approaches 2 + 5) ---
        uint256 swapSize = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        uint24 impactFee = _applyImpactGuards(poolId, trader, swapSize);
        if (impactFee > fee) fee = impactFee;

        if (fee > BASE_FEE) emit FeeEscalated(poolId, trader, BASE_FEE, fee);

        emit SwapTelemetry(poolId, trader, params.zeroForOne, params.amountSpecified, score, fee, block.number);

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------------
    // Trader identity resolution
    // ---------------------------------------------------------------------

    /// @notice Resolves the address a swap should be attributed to.
    ///
    /// Uniswap v4 passes the *caller* of `poolManager.swap()` into the hook.
    /// In practice that is a router, so naively using it collapses every trader
    /// behind a shared router into one identity: honest users inherit a bot's
    /// volume, and the router itself accumulates score until it crosses
    /// {REJECT_THRESHOLD} and bricks the pool for everyone.
    ///
    /// Resolution order:
    ///   1. `ITrustedRouter.getMsgSender()` on the router — but **only** when
    ///      `sender` is in {trustedRouters}. See the security note below.
    ///   2. An originator the same trusted router declared in `hookData`, for
    ///      routers that can forward bytes but cannot add a getter.
    ///   3. `tx.origin` — the EOA that signed the transaction.
    ///
    /// Paths 1 and 2 are the only ones that stay correct under ERC-4337, where
    /// `tx.origin` is the bundler rather than the account.
    ///
    /// @dev SECURITY — why the allow-list gate is load-bearing: anyone can
    ///      deploy a contract that calls the PoolManager directly, which makes
    ///      that contract the `sender` the hook receives. If the hook called
    ///      `getMsgSender()` on it unconditionally, the contract could return
    ///      any address at all — naming a clean address to launder its own
    ///      reputation, or an innocent one to get it penalised. `sender` is
    ///      therefore never trusted until it has been vetted by the owner.
    ///
    /// @dev The call is `view`, so the compiler emits a STATICCALL: a
    ///      misbehaving router cannot mutate state or re-enter. It is wrapped in
    ///      try/catch so a router that reverts, runs out of gas, or does not
    ///      implement the interface degrades to the next path instead of
    ///      failing the swap.
    ///
    /// @dev `tx.origin` is used for *attribution and pricing*, never for
    ///      authorization, so the usual phishing objection to `tx.origin` does
    ///      not apply: the worst case is that an address is charged for a swap
    ///      its own signature authorised. It also cannot be spoofed — forging it
    ///      would require the victim's private key.
    ///
    /// @dev An unrecognised `sender` deliberately falls through to `tx.origin`
    ///      rather than reverting. Reverting would make the pool permissioned —
    ///      only allow-listed routers could trade — which this hook does not do.
    function _resolveTrader(address sender, bytes calldata hookData) internal view returns (address) {
        if (trustedRouters[sender]) {
            // 1. Ask the router who called it.
            try ITrustedRouter(sender).getMsgSender() returns (address user) {
                if (user != address(0)) return user;
            } catch {
                // Fall through — router does not implement it, or reverted.
            }

            // 2. Originator declared in hookData. 32 bytes distinguishes this
            //    from the 160-byte score attestation {_resolveScore} reads.
            if (hookData.length == 32) {
                address declared = abi.decode(hookData, (address));
                if (declared != address(0)) return declared;
            }
        }

        // 3. Unknown router, or a trusted one that reported nothing usable.
        return tx.origin;
    }

    function _detectSandwich(PoolId poolId, address sender, bool zeroForOne) internal {
        bytes32 firstSlot = _firstSwapSlot(poolId, sender);
        uint256 recorded = _bload(firstSlot);
        bytes32 counterSlot = _blockSwapsSlot(poolId);
        uint256 swapCount = _bload(counterSlot);

        if (recorded != 0) {
            if ((recorded == _SWAP_ZERO_FOR_ONE) != zeroForOne && swapCount >= 2) {
                emit SandwichDetected(poolId, sender, block.number);
                _triggerScoreTask(sender, "sandwich");
            }
        } else {
            _bstore(firstSlot, zeroForOne ? _SWAP_ZERO_FOR_ONE : _SWAP_ONE_FOR_ZERO);
        }

        _bstore(counterSlot, swapCount + 1);
    }

    // ---------------------------------------------------------------------
    // Price impact guards
    // ---------------------------------------------------------------------

    function _applyImpactGuards(PoolId poolId, address sender, uint256 swapSize) internal returns (uint24) {
        uint24 fee = BASE_FEE;

        if (_pendingScoreFlag[sender]) {
            _pendingScoreFlag[sender] = false;
            _triggerScoreTask(sender, "impact_prior");
        }

        // Per-sender progressive fee: as a sender's cumulative volume in
        // one pool in one block grows, the fee escalates. Fully permissionless
        // — no reverts, any amount is tradeable. Sandwich back-runs become
        // unprofitable because the fee eats the extracted value.
        bytes32 senderSlot = _senderImpactSlot(poolId, sender);
        uint256 senderCumulative = _bload(senderSlot) + swapSize;
        _bstore(senderSlot, senderCumulative);

        uint24 senderFee = BASE_FEE;
        if (senderCumulative > SENDER_VOLUME_THRESHOLD * 4) {
            senderFee = IMPACT_FEE_TIER3;
        } else if (senderCumulative > SENDER_VOLUME_THRESHOLD * 2) {
            senderFee = IMPACT_FEE_TIER2;
        } else if (senderCumulative > SENDER_VOLUME_THRESHOLD) {
            senderFee = IMPACT_FEE_TIER1;
        }

        if (senderFee > BASE_FEE) {
            emit SenderImpactCapped(poolId, sender, senderCumulative, senderFee);
            _pendingScoreFlag[sender] = true;
            fee = senderFee;
        }

        // Pool-level guard: if cumulative volume across all senders exceeds
        // the threshold, escalate the fee.
        bytes32 poolSlot = _poolImpactSlot(poolId);
        uint256 poolCumulative = _bload(poolSlot) + swapSize;
        _bstore(poolSlot, poolCumulative);

        if (poolCumulative > POOL_IMPACT_THRESHOLD) {
            uint24 poolFee = IMPACT_FEE_TIER1;
            if (poolFee > fee) fee = poolFee;
            emit PoolImpactGuard(poolId, sender, poolCumulative, fee);
        }

        return fee;
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
    // Score resolution (hookData attestation or on-chain oracle fallback)
    // ---------------------------------------------------------------------

    function _resolveScore(address sender, bytes calldata hookData) internal view returns (uint16) {
        if (hookData.length == 0 || attestor == address(0)) {
            return oracle.getScore(sender);
        }

        if (hookData.length != 160) return oracle.getScore(sender);

        (uint16 score, uint64 expiry, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(hookData, (uint16, uint64, uint8, bytes32, bytes32));

        if (block.timestamp > expiry) return oracle.getScore(sender);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(abi.encodePacked(sender, score, expiry, block.chainid, address(this)))
            )
        );

        address recovered = ecrecover(digest, v, r, s);
        if (recovered != attestor) return oracle.getScore(sender);

        return score;
    }

    // ---------------------------------------------------------------------
    // JIT-liquidity detection
    // ---------------------------------------------------------------------

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        // Attributed to the provider, not the position-manager contract that
        // relays the call — same reasoning as {_resolveTrader} for swaps.
        _bstore(_liquiditySlot(poolId, _resolveTrader(sender, hookData)), 1);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        address provider = _resolveTrader(sender, hookData);
        if (_bload(_liquiditySlot(poolId, provider)) == 1) {
            emit JITDetected(poolId, provider, block.number);
            _triggerScoreTask(provider, "jit");
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // ---------------------------------------------------------------------
    // BLS task auto-trigger
    // ---------------------------------------------------------------------

    function _triggerScoreTask(address subject, string memory detectionType) internal {
        if (address(taskManager) == address(0)) return;

        // Rate-limit repeat tasks for the same subject. The zero check matters:
        // a never-scored address has _lastTaskBlock == 0, and without it the
        // cooldown would suppress every first offence until the chain passed
        // block TASK_COOLDOWN_BLOCKS.
        uint256 last = _lastTaskBlock[subject];
        if (last != 0 && last + TASK_COOLDOWN_BLOCKS > block.number) return;

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
    // Block-scoped state helpers
    // ---------------------------------------------------------------------
    //
    // These deliberately use persistent storage rather than transient storage
    // (EIP-1153). TSTORE/TLOAD is ~20k gas cheaper, but transient storage is
    // discarded at the end of each *transaction*, not each block — and a real
    // sandwich is three separate transactions (front-run, victim, back-run).
    // Transient state therefore never survives from the front-run to the
    // back-run, and no pattern would ever be detected on a live chain.
    //
    // Each entry stamps the block that wrote it into the high 64 bits, so a
    // read from a later block returns zero and the state resets itself without
    // an explicit sweep. Because a slot is reused block after block it stays
    // non-zero, costing ~2.9k gas per update instead of a cold 20k write.

    /// @dev Reads the payload only if it was written in the current block.
    function _bload(bytes32 slot) internal view returns (uint256) {
        uint256 packed = _blockState[slot];
        if (packed >> _BLOCK_SHIFT != block.number) return 0;
        return packed & _PAYLOAD_MASK;
    }

    /// @dev Writes the payload stamped with the current block.
    function _bstore(bytes32 slot, uint256 value) internal {
        _blockState[slot] = (block.number << _BLOCK_SHIFT) | (value & _PAYLOAD_MASK);
    }

    function _firstSwapSlot(PoolId poolId, address sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_FIRST_SWAP_NS, poolId, sender));
    }

    function _blockSwapsSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_BLOCK_SWAPS_NS, poolId));
    }

    function _liquiditySlot(PoolId poolId, address sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_LIQUIDITY_NS, poolId, sender));
    }

    function _poolImpactSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_POOL_IMPACT_NS, poolId));
    }

    function _senderImpactSlot(PoolId poolId, address sender) internal pure returns (bytes32) {
        return keccak256(abi.encode(_SENDER_IMPACT_NS, poolId, sender));
    }
}
