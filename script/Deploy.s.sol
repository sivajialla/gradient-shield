// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title Deploy
/// @notice SCAFFOLD STUB — testnet deployment with CREATE2 hook-address mining.
/// @dev v4 hooks must be deployed to an address whose low bits encode the hook's
///      permission flags. We mine a salt with {HookMiner} then deploy via the
///      canonical CREATE2 deployer so the resulting address carries the right flags.
///
/// Env vars (see README Step 5):
///   POOL_MANAGER  — PoolManager address on the target chain
///   PRIVATE_KEY   — deployer key
///   RPC_URL       — testnet RPC (passed on the CLI, not read here)
contract Deploy is Script {
    /// @notice Canonical CREATE2 deployer proxy (same address on every chain).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        // 1. Deploy the scoring oracle (AVS writer set later / via env).
        // TODO: pass the real AVS ServiceManager address instead of the deployer.
        ScoringOracle oracle = new ScoringOracle(vm.addr(pk));
        console2.log("ScoringOracle:", address(oracle));

        // 2. Mine a hook address with the flags GradientShieldHook declares.
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), oracle);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GradientShieldHook).creationCode, constructorArgs);

        // 3. Deploy to the mined address via CREATE2 (salt makes address == hookAddress).
        GradientShieldHook hook = new GradientShieldHook{salt: salt}(IPoolManager(poolManager), oracle);
        require(address(hook) == hookAddress, "Deploy: hook address mismatch");
        console2.log("GradientShieldHook:", address(hook));

        // 4. TODO: initialise a dynamic-fee pool that uses this hook, and point the
        //    oracle's AVS writer at the deployed EigenLayer ServiceManager.

        vm.stopBroadcast();
    }
}
