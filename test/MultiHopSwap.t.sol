// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @dev Helper to deposit ERC20 tokens into PoolManager as ERC6909 claims.
contract ClaimDepositor is IUnlockCallback {
    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function deposit(Currency currency, uint256 amount, address recipient) external {
        pm.unlock(abi.encode(currency, amount, recipient, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (Currency currency, uint256 amount, address recipient, address payer) =
            abi.decode(data, (Currency, uint256, address, address));

        pm.sync(currency);
        MockERC20(Currency.unwrap(currency)).transferFrom(payer, address(pm), amount);
        pm.settle();
        pm.mint(recipient, currency.toId(), amount);

        return "";
    }
}

contract MultiHopSwapTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;
    ClaimDepositor internal depositor;

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal tokenC;

    Currency internal currA;
    Currency internal currB;
    Currency internal currC;

    PoolKey internal keyAB;
    PoolKey internal keyBC;

    address internal trader = address(0xBEEF);

    function setUp() public {
        deployFreshManagerAndRouters();

        oracle = new ScoringOracle(address(0xA75));
        depositor = new ClaimDepositor(IPoolManager(manager));

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

        // Deploy 3 tokens and sort them
        tokenA = new MockERC20("TokenA", "A", 18);
        tokenB = new MockERC20("TokenB", "B", 18);
        tokenC = new MockERC20("TokenC", "C", 18);

        (tokenA, tokenB, tokenC) = _sortTokens(tokenA, tokenB, tokenC);
        currA = Currency.wrap(address(tokenA));
        currB = Currency.wrap(address(tokenB));
        currC = Currency.wrap(address(tokenC));

        // Mint tokens to test contract (LP) and trader
        tokenA.mint(address(this), 100e18);
        tokenB.mint(address(this), 100e18);
        tokenC.mint(address(this), 100e18);
        tokenA.mint(trader, 10e18);
        tokenB.mint(trader, 10e18);
        tokenC.mint(trader, 10e18);

        // Approve for LP operations
        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);
        tokenC.approve(address(manager), type(uint256).max);
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenC.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Trader approves depositor for ERC20 → ERC6909 claims
        vm.startPrank(trader);
        tokenA.approve(address(depositor), type(uint256).max);
        tokenB.approve(address(depositor), type(uint256).max);
        tokenC.approve(address(depositor), type(uint256).max);
        // Trader approves hook as ERC6909 operator on PoolManager
        IPoolManager(manager).setOperator(address(hook), true);
        vm.stopPrank();

        // Initialize pool A-B
        keyAB = PoolKey({
            currency0: currA,
            currency1: currB,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyAB, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(keyAB, LIQUIDITY_PARAMS, ZERO_BYTES);

        // Initialize pool B-C
        keyBC = PoolKey({
            currency0: currB,
            currency1: currC,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(keyBC, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(keyBC, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_multiHopSwap_A_to_C_viaERC6909() public {
        // Step 1: Trader deposits Token A into PoolManager as ERC6909 claims
        vm.prank(trader);
        depositor.deposit(currA, 5000, trader);

        uint256 claimA_before = IPoolManager(manager).balanceOf(trader, currA.toId());
        uint256 claimC_before = IPoolManager(manager).balanceOf(trader, currC.toId());

        assertTrue(claimA_before >= 5000, "should have A claims");

        // Step 2: Execute multi-hop A → B → C via ERC6909
        GradientShieldHook.SwapHop[] memory hops = new GradientShieldHook.SwapHop[](2);
        hops[0] = GradientShieldHook.SwapHop({
            key: keyAB,
            zeroForOne: true,
            amountSpecified: -1000,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            hookData: ""
        });
        hops[1] = GradientShieldHook.SwapHop({
            key: keyBC,
            zeroForOne: true,
            amountSpecified: -996,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            hookData: ""
        });

        Currency[] memory currencies = new Currency[](3);
        currencies[0] = currA;
        currencies[1] = currB;
        currencies[2] = currC;

        vm.prank(trader);
        hook.multiHopSwap(hops, currencies, block.timestamp + 1 hours);

        uint256 claimA_after = IPoolManager(manager).balanceOf(trader, currA.toId());
        uint256 claimC_after = IPoolManager(manager).balanceOf(trader, currC.toId());

        console2.log("=== Multi-Hop ERC6909: A -> B -> C ===");
        console2.log("  Claim A burned:", claimA_before - claimA_after);
        console2.log("  Claim C minted:", claimC_after - claimC_before);
        console2.log("  Token B never left PoolManager (intermediate cancelled)");

        assertTrue(claimA_after < claimA_before, "should burn A claims");
        assertTrue(claimC_after > claimC_before, "should mint C claims");
        // B claims should be near-zero — minor rounding dust from fee math
        uint256 bClaims = IPoolManager(manager).balanceOf(trader, currB.toId());
        assertTrue(bClaims <= 10, "B claims should be near-zero (rounding dust only)");
        console2.log("  B claim dust:", bClaims, "(rounding residual)");
    }

    function test_multiHopSwap_deadlineExpired() public {
        GradientShieldHook.SwapHop[] memory hops = new GradientShieldHook.SwapHop[](1);
        hops[0] = GradientShieldHook.SwapHop({
            key: keyAB,
            zeroForOne: true,
            amountSpecified: -100,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            hookData: ""
        });

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currA;
        currencies[1] = currB;

        vm.prank(trader);
        vm.expectRevert(GradientShieldHook.DeadlineExpired.selector);
        hook.multiHopSwap(hops, currencies, block.timestamp - 1);
    }

    function test_singleHopViaERC6909() public {
        // Deposit A claims
        vm.prank(trader);
        depositor.deposit(currA, 5000, trader);

        uint256 claimA_before = IPoolManager(manager).balanceOf(trader, currA.toId());
        uint256 claimB_before = IPoolManager(manager).balanceOf(trader, currB.toId());

        GradientShieldHook.SwapHop[] memory hops = new GradientShieldHook.SwapHop[](1);
        hops[0] = GradientShieldHook.SwapHop({
            key: keyAB,
            zeroForOne: true,
            amountSpecified: -1000,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1,
            hookData: ""
        });

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = currA;
        currencies[1] = currB;

        vm.prank(trader);
        hook.multiHopSwap(hops, currencies, block.timestamp + 1 hours);

        assertTrue(
            IPoolManager(manager).balanceOf(trader, currA.toId()) < claimA_before,
            "should burn A claims"
        );
        assertTrue(
            IPoolManager(manager).balanceOf(trader, currB.toId()) > claimB_before,
            "should mint B claims"
        );
    }

    function _sortTokens(MockERC20 a, MockERC20 b, MockERC20 c)
        internal
        pure
        returns (MockERC20, MockERC20, MockERC20)
    {
        if (address(a) > address(b)) (a, b) = (b, a);
        if (address(b) > address(c)) (b, c) = (c, b);
        if (address(a) > address(b)) (a, b) = (b, a);
        return (a, b, c);
    }
}
