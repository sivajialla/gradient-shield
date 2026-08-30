// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";
import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {GradientShieldTaskManager} from "../src/GradientShieldTaskManager.sol";
import {IGradientShieldTaskManager} from "../src/IGradientShieldTaskManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title Deploy
/// @notice Mainnet/testnet deployment for BLS-based GradientShield AVS.
/// @dev Requires EigenLayer core + BLS infrastructure (RegistryCoordinator,
///      BLSApkRegistry, StakeRegistry) already deployed on the target chain.
///
/// Required env vars:
///   PRIVATE_KEY, POOL_MANAGER, REGISTRY_COORDINATOR, STAKE_REGISTRY,
///   AVS_DIRECTORY, REWARDS_COORDINATOR, PERMISSION_CONTROLLER,
///   ALLOCATION_MANAGER, PAUSER_REGISTRY, AGGREGATOR, GENERATOR
contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        (ScoringOracle oracle, GradientShieldTaskManager tm) = _deployAVS(deployer);
        _deployHook(oracle, tm);

        vm.stopBroadcast();
    }

    function _deployAVS(address deployer)
        internal
        returns (ScoringOracle oracle, GradientShieldTaskManager tm)
    {
        oracle = new ScoringOracle(address(0));
        console2.log("ScoringOracle:", address(oracle));

        ISlashingRegistryCoordinator registryCoordinator =
            ISlashingRegistryCoordinator(vm.envAddress("REGISTRY_COORDINATOR"));

        // Deploy TaskManager (BLS-verified scoring)
        GradientShieldTaskManager tmImpl = new GradientShieldTaskManager(
            registryCoordinator,
            IPauserRegistry(vm.envAddress("PAUSER_REGISTRY")),
            100 // 100-block response window
        );
        ERC1967Proxy tmProxy = new ERC1967Proxy(
            address(tmImpl),
            abi.encodeCall(
                GradientShieldTaskManager.initialize,
                (deployer, vm.envAddress("AGGREGATOR"), vm.envAddress("GENERATOR"), oracle)
            )
        );
        tm = GradientShieldTaskManager(address(tmProxy));
        console2.log("TaskManager (proxy):", address(tm));

        // Deploy ServiceManager (AVS identity layer)
        GradientShieldServiceManager smImpl = new GradientShieldServiceManager(
            IAVSDirectory(vm.envAddress("AVS_DIRECTORY")),
            IRewardsCoordinator(vm.envAddress("REWARDS_COORDINATOR")),
            registryCoordinator,
            IStakeRegistry(vm.envAddress("STAKE_REGISTRY")),
            IPermissionController(vm.envAddress("PERMISSION_CONTROLLER")),
            IAllocationManager(vm.envAddress("ALLOCATION_MANAGER")),
            oracle
        );
        ERC1967Proxy smProxy = new ERC1967Proxy(
            address(smImpl),
            abi.encodeCall(
                GradientShieldServiceManager.initialize,
                (deployer, deployer, IGradientShieldTaskManager(address(tm)))
            )
        );
        console2.log("ServiceManager (proxy):", address(smProxy));

        oracle.setAvs(address(tm));
    }

    function _deployHook(ScoringOracle oracle, GradientShieldTaskManager tm) internal {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address attestorAddr = vm.envOr("ATTESTOR", address(0));

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager), oracle, IScoreTaskCreator(address(tm)), attestorAddr
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GradientShieldHook).creationCode, constructorArgs);

        GradientShieldHook hook = new GradientShieldHook{salt: salt}(
            IPoolManager(poolManager), oracle, IScoreTaskCreator(address(tm)), attestorAddr
        );
        require(address(hook) == hookAddress, "Deploy: hook address mismatch");
        console2.log("GradientShieldHook:", address(hook));

        tm.setHookAddress(address(hook));
        console2.log("Hook registered as task creator on TaskManager");
    }
}
