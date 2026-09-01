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
    //  TRUSTED ROUTER PATH (account abstraction)
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
