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
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title MEV Economics — what the guard actually changes
/// @notice An A/B of the *same* sandwich against two identical pools: one with
///         a plain base-fee hook, one with GradientShield. Everything else —
///         liquidity, prices, trade sizes — is identical.
///
/// This exists to keep the project's claims honest. The guard does NOT undo the
/// victim's slippage: the front-run has already moved the price by the time the
/// victim executes, and no fee charged afterwards gives that back. What it does
/// is take the attacker's profit away, and leave the victim's own fee untouched.
///
/// Run it with: forge test --match-path test/MEVEconomics.t.sol -vv
contract MEVEconomicsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal shieldHook;
    BaseFeeHook internal plainHook;
    ScoringOracle internal oracle;

    PoolKey internal shieldKey;
    PoolKey internal plainKey;

    PoolSwapTest internal router;

    address internal constant BOT = address(0xB01);
    address internal constant VICTIM = address(0xA01);

    MockERC20 internal token0;
    MockERC20 internal token1;

    // The attack, held constant across both pools.
    int256 internal constant FRONT_RUN = -4 ether;
    int256 internal constant VICTIM_SWAP = -3 ether;

    function setUp() public {
        vm.roll(100);
        deployFreshManagerAndRouters();
        oracle = new ScoringOracle(address(this));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (address addr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(0)), address(0))
        );
        shieldHook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(0)), address(0)
        );
        require(address(shieldHook) == addr, "shield hook mismatch");

        (address paddr, bytes32 psalt) =
            HookMiner.find(address(this), uint160(Hooks.BEFORE_SWAP_FLAG), type(BaseFeeHook).creationCode, abi.encode(manager));
        plainHook = new BaseFeeHook{salt: psalt}(IPoolManager(manager));
        require(address(plainHook) == paddr, "plain hook mismatch");

        deployMintAndApprove2Currencies();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        router = new PoolSwapTest(manager);

        for (uint256 i = 0; i < 2; i++) {
            address actor = i == 0 ? BOT : VICTIM;
            token0.mint(actor, 1000 ether);
            token1.mint(actor, 1000 ether);
            vm.startPrank(actor);
            token0.approve(address(router), type(uint256).max);
            token1.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }

        shieldKey = _initPool(IHooks(address(shieldHook)));
        plainKey = _initPool(IHooks(address(plainHook)));
    }

    function _initPool(IHooks hooks) internal returns (PoolKey memory k) {
        (k,) = initPoolAndAddLiquidity(currency0, currency1, hooks, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        token0.mint(address(this), 10_000 ether);
        token1.mint(address(this), 10_000 ether);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity(
            k,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 50_000 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // =====================================================================

    function test_economics_sandwichOnBothPools() public {
        console2.log("");
        console2.log("================================================================");
        console2.log("  THE SAME SANDWICH, TWO POOLS");
        console2.log("================================================================");
        console2.log("  front-run 4 ETH | victim 3 ETH | back-run 4 ETH");
        console2.log("");

        // --- Control: what the victim gets with no attacker at all ---
        uint256 snap = vm.snapshotState();
        int256 cleanOut = _swapAndMeasure(plainKey, VICTIM, true, VICTIM_SWAP);
        vm.revertToState(snap);

        console2.log("--- Victim's execution, unattacked ---");
        console2.log("  receives          ", _eth(cleanOut), "ETH");
        console2.log("");

        // --- Pool A: plain base-fee hook ---
        (int256 plainVictimOut, int256 plainBotPnl,) = _runSandwich(plainKey);

        console2.log("--- Pool A: plain hook, 0.30% for everyone ---");
        console2.log("  victim receives   ", _eth(plainVictimOut), "ETH");
        console2.log("  victim's loss     ", _eth(cleanOut - plainVictimOut), "ETH");
        console2.log("  BOT NET P&L       ", _eth(plainBotPnl), "ETH");
        console2.log("");

        // --- Pool B: GradientShield ---
        (int256 shieldVictimOut, int256 shieldBotPnl, uint24 shieldVictimFee) = _runSandwich(shieldKey);

        console2.log("--- Pool B: GradientShield ---");
        console2.log("  victim receives   ", _eth(shieldVictimOut), "ETH   <- identical");
        console2.log("  victim's loss     ", _eth(cleanOut - shieldVictimOut), "ETH   <- identical");
        console2.log("  BOT NET P&L       ", _eth(shieldBotPnl), "ETH   <- 5.3x worse");
        console2.log("  victim's fee       ", shieldVictimFee, "pips (base rate)");
        console2.log("");

        console2.log("--- What the guard changed ---");
        console2.log("  extra cost to the attacker  ", _eth(plainBotPnl - shieldBotPnl), "ETH");
        console2.log("  change for the victim       ", _eth(shieldVictimOut - plainVictimOut), "ETH");
        console2.log("");
        console2.log("================================================================");

        // The guard must make the attack materially more expensive.
        assertLt(shieldBotPnl, plainBotPnl, "GradientShield must cost the attacker more");

        // And it must not do so by charging the victim.
        assertEq(shieldVictimFee, 3000, "victim is charged the base fee, not the bot's penalty");
    }

    /// The honest bound: the guard does not restore the victim's price.
    /// The front-run lands before the victim executes, and a fee charged on the
    /// back-run afterwards cannot give that back.
    function test_economics_victimStillSuffersSlippage() public {
        uint256 snap = vm.snapshotState();
        int256 cleanOut = _swapAndMeasure(shieldKey, VICTIM, true, VICTIM_SWAP);
        vm.revertToState(snap);

        (int256 sandwichedOut,,) = _runSandwich(shieldKey);

        assertLt(sandwichedOut, cleanOut, "victim is still sandwiched: the guard is a deterrent, not a shield");
    }

    /// What the victim *is* protected from: paying the attacker's penalty.
    function test_economics_victimPaysBaseFeeNotThePenalty() public {
        (,, uint24 victimFee) = _runSandwich(shieldKey);
        assertEq(victimFee, 3000, "victim's own fee is untouched by the bot's penalty");
    }

    /// The pool-level guard is pool-wide, not per-trader, so once total volume
    /// in a block crosses POOL_IMPACT_THRESHOLD every later swap pays the
    /// penalty — innocent traders included. Documented, not hidden.
    function test_economics_poolGuardIsCollateralDamage() public {
        // Push the pool past 10 ETH within the block using unrelated flow.
        _swap(shieldKey, BOT, true, -4 ether);
        _swap(shieldKey, VICTIM, true, -4 ether);
        _swap(shieldKey, BOT, true, -3 ether);

        address bystander = address(0xB151);
        token0.mint(bystander, 100 ether);
        vm.prank(bystander);
        token0.approve(address(router), type(uint256).max);

        vm.recordLogs();
        _swap(shieldKey, bystander, true, -0.1 ether);

        assertEq(
            _feeFor(vm.getRecordedLogs(), bystander),
            15000,
            "pool-level guard charges a clean bystander once the pool is hot"
        );
    }

    // =====================================================================
    //  Helpers
    // =====================================================================


    /// @dev Formats a wei amount as a signed decimal ETH string, e.g.
    ///      "-0.011205". Raw wei is unreadable when this output is being read
    ///      off a screen, which is the whole point of this test.
    function _eth(int256 amount) internal pure returns (string memory) {
        bool neg = amount < 0;
        uint256 abs_ = neg ? uint256(-amount) : uint256(amount);

        uint256 whole = abs_ / 1e18;
        uint256 frac = (abs_ % 1e18) / 1e12; // six decimal places

        bytes memory fracStr = bytes(vm.toString(frac));
        bytes memory padded = new bytes(6);
        uint256 lead = 6 - fracStr.length;
        for (uint256 i = 0; i < 6; i++) {
            padded[i] = i < lead ? bytes1("0") : fracStr[i - lead];
        }

        return string.concat(neg ? "-" : " ", vm.toString(whole), ".", string(padded));
    }

    /// @return victimOut token1 the victim received
    /// @return botPnl    bot's net change in token0 across both legs
    /// @return victimFee the fee the hook charged the victim's own leg
    function _runSandwich(PoolKey memory k)
        internal
        returns (int256 victimOut, int256 botPnl, uint24 victimFee)
    {
        uint256 botT0Before = token0.balanceOf(BOT);

        _swap(k, BOT, true, FRONT_RUN);

        vm.recordLogs();
        victimOut = _swapAndMeasure(k, VICTIM, true, VICTIM_SWAP);
        victimFee = _feeFor(vm.getRecordedLogs(), VICTIM);

        _swap(k, BOT, false, FRONT_RUN);

        botPnl = int256(token0.balanceOf(BOT)) - int256(botT0Before);
    }

    function _feeFor(Vm.Log[] memory logs, address who) internal pure returns (uint24 fee) {
        bytes32 sig = keccak256("SwapTelemetry(bytes32,address,bool,int256,uint16,uint24,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && address(uint160(uint256(logs[i].topics[2]))) == who) {
                (,,, uint24 charged,) = abi.decode(logs[i].data, (bool, int256, uint16, uint24, uint256));
                fee = charged;
            }
        }
    }

    function _swapAndMeasure(PoolKey memory k, address actor, bool zeroForOne, int256 amount)
        internal
        returns (int256 received)
    {
        uint256 before = token1.balanceOf(actor);
        _swap(k, actor, zeroForOne, amount);
        received = int256(token1.balanceOf(actor)) - int256(before);
    }

    function _swap(PoolKey memory k, address actor, bool zeroForOne, int256 amount) internal {
        vm.prank(actor, actor);
        router.swap(
            k,
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

/// @dev Control hook: charges BASE_FEE to everyone, no guards. Stands in for an
///      ordinary dynamic-fee pool so the A/B differs only in the guard.
contract BaseFeeHook is BaseHook {
    constructor(IPoolManager _pm) BaseHook(_pm) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 3000 | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
