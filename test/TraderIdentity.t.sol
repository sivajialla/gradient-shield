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
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Trader Identity Resolution
/// @notice The hook must score the **trader**, not the router.
///
/// Uniswap v4 hands `beforeSwap` whoever called `poolManager.swap()`, which in
/// practice is a router. Keying on that address collapsed every trader behind a
/// shared router into a single identity, with two concrete consequences:
///
///   • an honest user inherited a bot's per-block volume and paid its penalty;
///   • the router itself accumulated score until it crossed the reject
///     threshold, at which point the pool was bricked for everyone.
///
/// {GradientShieldHook._resolveTrader} fixes this. These tests pin the fix down,
/// including the two failure modes above.
contract TraderIdentityTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    /// One router shared by everyone, exactly like a real Universal Router.
    PoolSwapTest internal sharedRouter;

    address internal constant BOT = address(0xB01);
    address internal constant HONEST = address(0xA01);
    address internal constant OTHER = address(0xA02);
    address internal constant BUNDLER = address(0xB0D1E);
    address internal constant SMART_ACCOUNT = address(0x5A11);

    address internal avs = address(0xA75);

    function setUp() public {
        vm.roll(100);
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
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));

        sharedRouter = new PoolSwapTest(manager);
        t0.approve(address(sharedRouter), type(uint256).max);
        t1.approve(address(sharedRouter), type(uint256).max);

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
    //  THE TWO BUGS THIS FIXES
    // =====================================================================

    /// Regression: an honest user behind a shared router used to inherit a
    /// bot's volume and pay its penalty fee.
    function test_honestUserDoesNotInheritBotVolume() public {
        // Bot pushes 4 ETH through the shared router — under the 5 ETH threshold.
        _swapAs(BOT, true, -4 ether);

        // An unrelated honest user does a 2 ETH swap through the same router in
        // the same block. Their own volume is 2 ETH, so they owe the base fee.
        vm.recordLogs();
        _swapAs(HONEST, true, -2 ether);

        assertEq(_feeFrom(vm.getRecordedLogs(), HONEST), 3000, "honest user pays base fee");
    }

    /// Regression: the router itself used to accumulate score until it crossed
    /// REJECT_THRESHOLD, which bricked the pool for every user behind it.
    function test_routerNeverAccumulatesScore() public {
        _swapAs(BOT, true, -1 ether);
        _swapAs(HONEST, true, -1 ether);

        assertEq(oracle.getScore(address(sharedRouter)), 0, "router is not an identity");

        // Even with the router scored into the reject band, trading continues:
        // the hook never reads the router's score.
        vm.prank(avs);
        oracle.setScore(address(sharedRouter), 100);

        _swapAs(HONEST, true, -1 ether);
        _swapAs(OTHER, true, -1 ether);
    }

    // =====================================================================
    //  ATTRIBUTION
    // =====================================================================

    function test_telemetryNamesTheTrader() public {
        vm.recordLogs();
        _swapAs(BOT, true, -1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        address swapper;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) swapper = address(uint160(uint256(logs[i].topics[2])));
        }
        assertEq(swapper, BOT, "telemetry must name the trader");
        assertTrue(swapper != address(sharedRouter), "and must not name the router");
    }

    function test_scoreFollowsTraderAcrossRouters() public {
        vm.prank(avs);
        oracle.setScore(BOT, 60);

        PoolSwapTest otherRouter = new PoolSwapTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(otherRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(otherRouter), type(uint256).max);

        // Same trader, a different router — same escalated fee. Score 60 maps
        // to 3000 + 12000 * 20/40 = 9000.
        vm.recordLogs();
        vm.prank(address(this), BOT);
        otherRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(_feeFrom(vm.getRecordedLogs(), BOT), 9000, "score travels with the trader");
    }

    function test_perTraderVolumeBudgets() public {
        // Three traders each do 4 ETH through one router. Nobody crosses the
        // 5 ETH per-trader threshold, though the pool total is 12 ETH.
        _swapAs(BOT, true, -4 ether);
        _swapAs(HONEST, true, -4 ether);

        vm.recordLogs();
        _swapAs(OTHER, true, -4 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 capSig = keccak256("SenderImpactCapped(bytes32,address,uint256,uint24)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(logs[i].topics[0] == capSig, "no trader crossed their own threshold");
        }
    }

    function test_sameTraderAccumulatesAcrossRouters() public {
        PoolSwapTest otherRouter = new PoolSwapTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(otherRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(otherRouter), type(uint256).max);

        // 3 ETH on one router, 3 ETH on another — the trader's budget is shared,
        // so splitting routers no longer dodges the volume threshold.
        _swapAs(BOT, true, -3 ether);

        vm.recordLogs();
        vm.prank(address(this), BOT);
        otherRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -3 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(_feeFrom(vm.getRecordedLogs(), BOT), 15000, "6 ETH total crosses the threshold");
    }

    function test_rejectionAppliesToTraderNotRouter() public {
        vm.prank(avs);
        oracle.setScore(BOT, 85);

        vm.expectRevert();
        _swapAs(BOT, true, -1 ether);

        // A different trader on the same router is unaffected.
        _swapAs(HONEST, true, -1 ether);
    }

    // =====================================================================
    //  TRUSTED ROUTER — getMsgSender() PATH
    // =====================================================================

    function test_getMsgSender_authorizedRouterIsBelieved() public {
        SpoofingRouter router = new SpoofingRouter(manager, SMART_ACCOUNT);
        _fundRouter(router);
        hook.setTrustedRouter(address(router), true);

        // tx.origin is a bundler; the router reports the real account.
        vm.recordLogs();
        _swapViaRouter(router, BUNDLER, true, -1 ether);

        assertEq(_swapperFrom(vm.getRecordedLogs()), SMART_ACCOUNT, "authorized router's getMsgSender() is used");
    }

    /// The load-bearing security check. An unauthorized contract can call the
    /// PoolManager directly, which makes it the `sender` the hook receives. If
    /// the hook called getMsgSender() on it, the contract could name any
    /// address — laundering its own reputation or framing an innocent one.
    function test_getMsgSender_unauthorizedRouterIsNeverCalled() public {
        // This router will happily claim to be an innocent address.
        SpoofingRouter attacker = new SpoofingRouter(manager, HONEST);
        _fundRouter(attacker);
        // Deliberately NOT added to trustedRouters.

        vm.prank(avs);
        oracle.setScore(BOT, 85);

        // The bot drives the spoofing router, which claims to be HONEST
        // (score 0). If the hook believed an unvetted sender the swap would go
        // through; instead the bot's own score 85 applies and it reverts.
        vm.expectRevert();
        _swapViaRouter(attacker, BOT, true, -1 ether);

        // And the claim buys nothing even when the claimed address is clean:
        // an unvetted router is simply never asked.
        vm.recordLogs();
        _swapViaRouter(attacker, OTHER, true, -1 ether);
        assertEq(_swapperFrom(vm.getRecordedLogs()), OTHER, "unvetted claim ignored; tx.origin used");
    }

    /// The getter is called via STATICCALL, so a trusted-but-buggy router
    /// cannot mutate state or re-enter through it.
    function test_getMsgSender_stateMutatingGetterIsRejected() public {
        MutatingRouter router = new MutatingRouter(manager);
        _fundRouter(router);
        hook.setTrustedRouter(address(router), true);

        vm.recordLogs();
        _swapViaRouter(router, BOT, true, -1 ether);

        assertEq(_swapperFrom(vm.getRecordedLogs()), BOT, "staticcall blocks the write, hook falls back");
        assertEq(router.calls(), 0, "no state change survived");
    }

    /// Revoking trust must take effect immediately.
    function test_getMsgSender_deauthorizedRouterIsIgnored() public {
        SpoofingRouter router = new SpoofingRouter(manager, SMART_ACCOUNT);
        _fundRouter(router);

        hook.setTrustedRouter(address(router), true);
        vm.recordLogs();
        _swapViaRouter(router, BUNDLER, true, -1 ether);
        assertEq(_swapperFrom(vm.getRecordedLogs()), SMART_ACCOUNT);

        hook.setTrustedRouter(address(router), false);
        vm.recordLogs();
        _swapViaRouter(router, BUNDLER, true, -1 ether);
        assertEq(_swapperFrom(vm.getRecordedLogs()), BUNDLER, "revoked router falls back to tx.origin");
    }

    /// A trusted router that reverts, runs out of gas, or does not implement
    /// the interface must degrade, not break the swap.
    function test_getMsgSender_revertingRouterFallsBackNotReverts() public {
        RevertingRouter router = new RevertingRouter(manager);
        _fundRouter(router);
        hook.setTrustedRouter(address(router), true);

        vm.recordLogs();
        _swapViaRouter(router, BOT, true, -1 ether);

        assertEq(_swapperFrom(vm.getRecordedLogs()), BOT, "reverting getter falls back to tx.origin");
    }

    function test_getMsgSender_zeroAddressFallsBack() public {
        SpoofingRouter router = new SpoofingRouter(manager, address(0));
        _fundRouter(router);
        hook.setTrustedRouter(address(router), true);

        vm.recordLogs();
        _swapViaRouter(router, BOT, true, -1 ether);

        assertEq(_swapperFrom(vm.getRecordedLogs()), BOT, "a zero report falls back to tx.origin");
    }

    /// An unrecognised router must still be able to trade. Reverting on an
    /// unknown sender would make the pool permissioned.
    function test_unknownRouter_stillPermissionless() public {
        PoolSwapTest plainRouter = new PoolSwapTest(manager);
        MockERC20(Currency.unwrap(currency0)).approve(address(plainRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(plainRouter), type(uint256).max);

        vm.recordLogs();
        vm.prank(address(this), HONEST);
        plainRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        assertEq(_swapperFrom(vm.getRecordedLogs()), HONEST, "unknown routers work, attributed by tx.origin");
    }

    // =====================================================================
    //  TRUSTED ROUTER — hookData PATH (routers that cannot add a getter)
    // =====================================================================

    function test_trustedRouter_declaredOriginatorIsUsed() public {
        hook.setTrustedRouter(address(sharedRouter), true);

        // tx.origin is a bundler; the router declares the real account.
        address bundler = address(0xB0D1E);
        address smartAccount = address(0x5A11);

        vm.recordLogs();
        vm.prank(address(this), bundler);
        sharedRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(smartAccount)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        address swapper;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) swapper = address(uint160(uint256(logs[i].topics[2])));
        }
        assertEq(swapper, smartAccount, "trusted router's declared originator wins over tx.origin");
    }

    /// An untrusted router declaring an originator must be ignored — otherwise
    /// any bot could simply name a clean address.
    function test_untrustedRouter_cannotSpoofOriginator() public {
        vm.prank(avs);
        oracle.setScore(BOT, 85);

        // The bot claims to be an innocent address through an untrusted router.
        vm.expectRevert();
        vm.prank(address(this), BOT);
        sharedRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(HONEST)
        );
    }

    function test_trustedRouter_zeroAddressFallsBackToOrigin() public {
        hook.setTrustedRouter(address(sharedRouter), true);

        vm.recordLogs();
        vm.prank(address(this), BOT);
        sharedRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(0))
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        address swapper;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) swapper = address(uint160(uint256(logs[i].topics[2])));
        }
        assertEq(swapper, BOT, "a zero declaration falls back to tx.origin");
    }

    // =====================================================================
    //  REGISTRY ACCESS CONTROL
    // =====================================================================

    function test_registry_onlyOwnerCanTrustRouters() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(GradientShieldHook.NotOwner.selector);
        hook.setTrustedRouter(address(sharedRouter), true);
    }

    function test_registry_rejectsZeroAddress() public {
        vm.expectRevert(GradientShieldHook.ZeroAddress.selector);
        hook.setTrustedRouter(address(0), true);
    }

    function test_registry_ownershipTransferAndRenounce() public {
        assertEq(hook.owner(), address(this));

        hook.transferOwnership(HONEST);
        assertEq(hook.owner(), HONEST);

        vm.expectRevert(GradientShieldHook.NotOwner.selector);
        hook.setTrustedRouter(address(sharedRouter), true);

        vm.prank(HONEST);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));
    }

    /// The owner's power is deliberately narrow: it cannot touch scores.
    function test_registry_ownerCannotSetScores() public {
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(BOT, 90);
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    /// @dev msg.sender stays this contract (it holds the tokens); tx.origin is
    ///      the trader, which is what the hook resolves.
    function _swapAs(address trader, bool zeroForOne, int256 amount) internal {
        vm.prank(address(this), trader);
        sharedRouter.swap(
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

    function _swapViaRouter(IdentityRouter router, address origin, bool zeroForOne, int256 amount) internal {
        vm.prank(address(this), origin);
        router.doSwap(key, zeroForOne, amount);
    }

    function _fundRouter(IdentityRouter router) internal {
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(address(router), 1000 ether);
        t1.mint(address(router), 1000 ether);
    }

    /// @dev The `swapper` topic of the single SwapTelemetry event in `logs`.
    function _swapperFrom(Vm.Log[] memory logs) internal pure returns (address swapper) {
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) swapper = address(uint160(uint256(logs[i].topics[2])));
        }
    }

    function _feeFrom(Vm.Log[] memory logs, address trader) internal pure returns (uint24 fee) {
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && address(uint160(uint256(logs[i].topics[2]))) == trader) {
                (,,, uint24 charged,) = abi.decode(logs[i].data, (bool, int256, uint16, uint24, uint256));
                fee = charged;
            }
        }
    }
}

// =========================================================================
//  Mock routers
// =========================================================================

/// @dev A minimal router that calls the PoolManager directly, so the hook sees
///      *this contract* as `sender`. It settles from its own token balance, so
///      tests only need to fund it.
abstract contract IdentityRouter is IUnlockCallback {
    using CurrencySettler for Currency;

    // TickMath.MIN_SQRT_PRICE + 1 / MAX_SQRT_PRICE - 1
    uint160 internal constant MIN_LIMIT = 4295128740;
    uint160 internal constant MAX_LIMIT = 1461446703485210103287273052203988822378723970341;

    IPoolManager public immutable manager;

    struct CallbackData {
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function doSwap(PoolKey memory key, bool zeroForOne, int256 amount) external {
        manager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    params: SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: amount,
                        sqrtPriceLimitX96: zeroForOne ? MIN_LIMIT : MAX_LIMIT
                    })
                })
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        CallbackData memory d = abi.decode(data, (CallbackData));

        BalanceDelta delta = manager.swap(d.key, d.params, "");

        _resolve(d.key.currency0, delta.amount0());
        _resolve(d.key.currency1, delta.amount1());
        return "";
    }

    function _resolve(Currency currency, int128 amount) internal {
        if (amount < 0) {
            currency.settle(manager, address(this), uint256(uint128(-amount)), false);
        } else if (amount > 0) {
            currency.take(manager, address(this), uint256(uint128(amount)), false);
        }
    }
}

/// @dev Reports whatever address it was constructed with. Used both as a
///      well-behaved trusted router and as an attacker trying to spoof a
///      trader from an unauthorized address.
contract SpoofingRouter is IdentityRouter {
    address public immutable claimed;

    constructor(IPoolManager _manager, address _claimed) IdentityRouter(_manager) {
        claimed = _claimed;
    }

    function getMsgSender() external view returns (address) {
        return claimed;
    }
}

/// @dev A router whose getter tries to write storage. The hook issues a
///      STATICCALL, so the write reverts and the hook falls back — a router
///      cannot use this entrypoint to re-enter or mutate anything.
contract MutatingRouter is IdentityRouter {
    uint256 public calls;

    constructor(IPoolManager _manager) IdentityRouter(_manager) {}

    function getMsgSender() external returns (address) {
        calls++; // reverts under STATICCALL
        return address(0xDEAD);
    }
}

/// @dev A trusted router whose getter reverts — the hook must degrade to
///      tx.origin rather than failing the swap.
contract RevertingRouter is IdentityRouter {
    constructor(IPoolManager _manager) IdentityRouter(_manager) {}

    function getMsgSender() external pure returns (address) {
        revert("no sender available");
    }
}
