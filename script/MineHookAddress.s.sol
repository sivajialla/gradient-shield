// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";

/// @title MineHookAddress
/// @notice Mines a CREATE2 hook address whose bottom 14 bits encode the
///         required permission flags. Run this BEFORE deploying to know
///         your hook address ahead of time.
///
/// Required env vars:
///   POOL_MANAGER   — PoolManager address on the target chain
///
/// Optional env vars (default to address(0) for local testing):
///   ORACLE         — ScoringOracle address
///   TASK_MANAGER   — TaskManager / IScoreTaskCreator address
///
/// Usage:
///   forge script script/MineHookAddress.s.sol
contract MineHookAddress is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address oracleAddr = vm.envOr("ORACLE", address(0));
        address taskManagerAddr = vm.envOr("TASK_MANAGER", address(0));
        address attestorAddr = vm.envOr("ATTESTOR", address(0));

        // These are the hook permissions encoded in the address bits
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        console2.log("=== GradientShield Hook Address Miner ===");
        console2.log("");
        console2.log("Permission flags enabled:");
        console2.log("  - beforeSwap");
        console2.log("  - beforeAddLiquidity");
        console2.log("  - beforeRemoveLiquidity");
        console2.log("");
        console2.log("Inputs:");
        console2.log("  CREATE2 deployer:", CREATE2_DEPLOYER);
        console2.log("  PoolManager:     ", poolManager);
        console2.log("  Oracle:          ", oracleAddr);
        console2.log("  TaskManager:     ", taskManagerAddr);
        console2.log("  Attestor:        ", attestorAddr);
        console2.log("");

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            ScoringOracle(oracleAddr),
            IScoreTaskCreator(taskManagerAddr),
            attestorAddr
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(GradientShieldHook).creationCode,
            constructorArgs
        );

        console2.log("=== RESULTS ===");
        console2.log("  Hook address:", hookAddress);
        console2.log("  Salt:        ", vm.toString(salt));
        console2.log("");
        console2.log("Verify flag bits (last 14 bits of address):");
        console2.log("  beforeSwap:           ", uint160(hookAddress) & Hooks.BEFORE_SWAP_FLAG != 0 ? "YES" : "NO");
        console2.log("  beforeAddLiquidity:   ", uint160(hookAddress) & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0 ? "YES" : "NO");
        console2.log("  beforeRemoveLiquidity:", uint160(hookAddress) & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0 ? "YES" : "NO");
    }
}
