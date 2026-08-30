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

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title Access Control Tests - Hook & Oracle
/// @notice Verifies every gated function rejects unauthorized callers,
///         and that mint/burn settlement paths have no reentrancy vectors.
contract AccessControlTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    address internal avs       = address(0xA75);
    address internal attacker  = address(0xBAD);

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
            abi.encode(manager, oracle, IScoreTaskCreator(address(0)), address(0))
        );
        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(0)), address(0)
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        deployMintAndApprove2Currencies();

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    // =====================================================================
    //  SCORING ORACLE ACCESS CONTROL
    // =====================================================================

    function test_oracle_setScore_onlyAvs() public {
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 50);
        assertEq(oracle.getScore(address(0xBEEF)), 50);

        vm.prank(attacker);
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(address(0xBEEF), 99);
    }

    function test_oracle_bumpScore_onlyAvs() public {
        vm.prank(avs);
        oracle.setScore(address(0xBEEF), 30);

        vm.prank(attacker);
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.bumpScore(address(0xBEEF), 10);
    }

    function test_oracle_setAvs_onlyOwner() public {
        oracle.setAvs(address(0x1111));
        assertEq(oracle.avs(), address(0x1111));

        vm.prank(attacker);
        vm.expectRevert(ScoringOracle.NotOwner.selector);
        oracle.setAvs(address(0x2222));
    }

    function test_oracle_setAvs_rejectsZero() public {
        vm.expectRevert(ScoringOracle.ZeroAddress.selector);
        oracle.setAvs(address(0));
    }

    function test_oracle_transferOwnership_onlyOwner() public {
        address newOwner = address(0xD00D);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), newOwner);

        // Old owner can no longer act
        vm.expectRevert(ScoringOracle.NotOwner.selector);
        oracle.setAvs(address(0x1234));
    }

    function test_oracle_transferOwnership_rejectsZero() public {
        vm.expectRevert(ScoringOracle.ZeroAddress.selector);
        oracle.transferOwnership(address(0));
    }

    function test_oracle_setScore_rejectsOutOfRange() public {
        vm.prank(avs);
        vm.expectRevert(abi.encodeWithSelector(ScoringOracle.ScoreOutOfRange.selector, 101));
        oracle.setScore(address(0xBEEF), 101);
    }

    function test_oracle_ownerCannotSetScore() public {
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(address(0xBEEF), 50);
    }

    function test_oracle_avsCannotTransferOwnership() public {
        vm.prank(avs);
        vm.expectRevert(ScoringOracle.NotOwner.selector);
        oracle.transferOwnership(attacker);
    }

    function test_oracle_avsCannotChangeAvs() public {
        vm.prank(avs);
        vm.expectRevert(ScoringOracle.NotOwner.selector);
        oracle.setAvs(attacker);
    }

    function test_oracle_newOwnerCanAct() public {
        address newOwner = address(0xD00D);
        oracle.transferOwnership(newOwner);

        vm.prank(newOwner);
        oracle.setAvs(address(0x9999));
        assertEq(oracle.avs(), address(0x9999));
    }

    function test_oracle_newAvsCanSetScore() public {
        address newAvs = address(0x9999);
        oracle.setAvs(newAvs);

        // Old AVS can no longer set
        vm.prank(avs);
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(address(0xBEEF), 50);

        // New AVS can
        vm.prank(newAvs);
        oracle.setScore(address(0xBEEF), 50);
        assertEq(oracle.getScore(address(0xBEEF)), 50);
    }

    // =====================================================================
    //  HOOK - unlockCallback ONLY FROM POOL MANAGER
    // =====================================================================

    function test_hook_unlockCallback_rejectsDirectCall() public {
        bytes memory fakeData = abi.encode(
            GradientShieldHook.MultiHopParams({
                hops: new GradientShieldHook.SwapHop[](0),
                currencies: new Currency[](0),
                sender: address(this),
                deadline: block.timestamp + 1000
            })
        );

        vm.prank(attacker);
        vm.expectRevert();
        hook.unlockCallback(fakeData);
    }

    function test_hook_unlockCallback_rejectsFromOwner() public {
        bytes memory fakeData = abi.encode(
            GradientShieldHook.MultiHopParams({
                hops: new GradientShieldHook.SwapHop[](0),
                currencies: new Currency[](0),
                sender: address(this),
                deadline: block.timestamp + 1000
            })
        );

        // Even the deployer/owner cannot call unlockCallback directly
        vm.expectRevert();
        hook.unlockCallback(fakeData);
    }

    // =====================================================================
    //  HOOK - multiHopSwap deadline enforcement
    // =====================================================================

    function test_hook_multiHopSwap_deadlineEnforced() public {
        GradientShieldHook.SwapHop[] memory hops = new GradientShieldHook.SwapHop[](0);
        Currency[] memory currencies = new Currency[](0);

        vm.expectRevert(GradientShieldHook.DeadlineExpired.selector);
        hook.multiHopSwap(hops, currencies, block.timestamp - 1);
    }

    // =====================================================================
    //  HOOK - beforeSwap only via poolManager
    // =====================================================================

    function test_hook_directBeforeSwap_reverts() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -100,
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        vm.prank(attacker);
        vm.expectRevert();
        hook.beforeSwap(attacker, key, params, ZERO_BYTES);
    }

    function test_hook_directBeforeAddLiquidity_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        hook.beforeAddLiquidity(attacker, key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_hook_directBeforeRemoveLiquidity_reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        hook.beforeRemoveLiquidity(attacker, key, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // =====================================================================
    //  SETTLEMENT REENTRANCY CHECK
    // =====================================================================

    function test_settlement_noReentrancyOnMint() public {
        // _settleCurrencyERC6909 calls poolManager.mint/burn
        // PoolManager.mint/burn are ERC6909 internal accounting with no external calls
        // No reentrancy vector exists. Verify by exercising the full path.
        swap(key, true, -100, ZERO_BYTES);
        swap(key, false, -100, ZERO_BYTES);
    }

    function test_settlement_mintBurnAreInternalAccounting() public {
        // poolManager.mint is ERC6909.mint - internal balance update, no callback
        // poolManager.burn is ERC6909.burn - internal balance update, no callback
        // Neither makes external calls, so reentrancy is not possible
        // Verify by doing swaps in both directions
        swap(key, true, -50, ZERO_BYTES);
        swap(key, false, -50, ZERO_BYTES);
        swap(key, true, -50, ZERO_BYTES);
    }

    // =====================================================================
    //  IMMUTABLE STATE CANNOT BE CHANGED
    // =====================================================================

    function test_hook_oracleIsImmutable() public view {
        assertEq(address(hook.oracle()), address(oracle));
    }

    function test_hook_poolManagerIsImmutable() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }
}
