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
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

contract HookDataAttestationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    GradientShieldHook internal hook;
    ScoringOracle internal oracle;

    uint256 internal attestorPk = 0xA11CE;
    address internal attestorAddr;
    address internal avs = address(0xA75);

    function setUp() public {
        attestorAddr = vm.addr(attestorPk);
        deployFreshManagerAndRouters();

        oracle = new ScoringOracle(avs);

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(GradientShieldHook).creationCode,
            abi.encode(manager, oracle, IScoreTaskCreator(address(0)), attestorAddr)
        );
        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(manager), oracle, IScoreTaskCreator(address(0)), attestorAddr
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        deployMintAndApprove2Currencies();

        (key,) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    function test_attestedScoreUsedOverOracle() public {
        // Oracle says score=0, but attestation says score=50 → fee should be 6000
        uint16 attestedScore = 50;
        uint64 expiry = uint64(block.timestamp + 1 hours);

        bytes memory hookData = _signAttestation(tx.origin, attestedScore, expiry);

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 6000);

        swap(key, true, -100, hookData);
    }

    function test_expiredAttestationFallsBackToOracle() public {
        uint16 attestedScore = 50;
        uint64 expiry = uint64(block.timestamp - 1);

        bytes memory hookData = _signAttestation(tx.origin, attestedScore, expiry);

        // Expired attestation → falls back to oracle (score=0 → base fee, no FeeEscalated event)
        swap(key, true, -100, hookData);
    }

    function test_invalidSignatureFallsBackToOracle() public {
        uint16 attestedScore = 50;
        uint64 expiry = uint64(block.timestamp + 1 hours);

        // Sign with wrong key
        uint256 wrongPk = 0xBAD;
        bytes32 innerHash = keccak256(
            abi.encodePacked(tx.origin, attestedScore, expiry, block.chainid, address(hook))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory hookData = abi.encode(attestedScore, expiry, v, r, s);

        // Invalid sig → falls back to oracle (score=0 → base fee)
        swap(key, true, -100, hookData);
    }

    function test_attestedScoreRejectsBotAboveThreshold() public {
        uint16 attestedScore = 85;
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes memory hookData = _signAttestation(tx.origin, attestedScore, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(GradientShieldHook.BotRejected.selector, tx.origin, uint16(85)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -100, hookData);
    }

    function test_emptyHookDataUsesOracle() public {
        vm.prank(avs);
        oracle.setScore(tx.origin, 50);

        PoolId poolId = key.toId();
        vm.expectEmit(true, true, false, true);
        emit GradientShieldHook.FeeEscalated(poolId, tx.origin, 3000, 6000);

        swap(key, true, -100, ZERO_BYTES);
    }

    function _signAttestation(address sender, uint16 score, uint64 expiry) internal view returns (bytes memory) {
        bytes32 innerHash = keccak256(
            abi.encodePacked(sender, score, expiry, block.chainid, address(hook))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestorPk, digest);
        return abi.encode(score, expiry, v, r, s);
    }
}
