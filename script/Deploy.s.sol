// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {ECDSAStakeRegistry} from "eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IECDSAStakeRegistryTypes} from "eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title Deploy
/// @notice Testnet deployment with CREATE2 hook-address mining.
/// @dev Requires EigenLayer core contracts to be deployed on the target chain.
contract Deploy is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        (ScoringOracle oracle, GradientShieldServiceManager sm) = _deployAVS(deployer);
        _deployHook(oracle);

        vm.stopBroadcast();
    }

    function _deployAVS(address deployer)
        internal
        returns (ScoringOracle oracle, GradientShieldServiceManager sm)
    {
        oracle = new ScoringOracle(address(0));
        console2.log("ScoringOracle:", address(oracle));

        ECDSAStakeRegistry stakeRegistry = new ECDSAStakeRegistry(
            IDelegationManager(vm.envAddress("DELEGATION_MANAGER"))
        );
        console2.log("ECDSAStakeRegistry:", address(stakeRegistry));

        GradientShieldServiceManager impl = new GradientShieldServiceManager(
            vm.envAddress("AVS_DIRECTORY"),
            address(stakeRegistry),
            vm.envAddress("REWARDS_COORDINATOR"),
            vm.envAddress("DELEGATION_MANAGER"),
            vm.envAddress("ALLOCATION_MANAGER"),
            oracle
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GradientShieldServiceManager.initialize, (deployer, deployer))
        );
        sm = GradientShieldServiceManager(address(proxy));
        console2.log("ServiceManager (proxy):", address(sm));

        IECDSAStakeRegistryTypes.StrategyParams[] memory sp =
            new IECDSAStakeRegistryTypes.StrategyParams[](1);
        sp[0] = IECDSAStakeRegistryTypes.StrategyParams({
            strategy: IStrategy(vm.envAddress("STRATEGY")),
            multiplier: 10_000
        });
        stakeRegistry.initialize(
            address(sm), 0, IECDSAStakeRegistryTypes.Quorum({strategies: sp})
        );

        oracle.setAvs(address(sm));
    }

    function _deployHook(ScoringOracle oracle) internal {
        address poolManager = vm.envAddress("POOL_MANAGER");

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );

        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), oracle);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GradientShieldHook).creationCode, constructorArgs);

        GradientShieldHook hook = new GradientShieldHook{salt: salt}(IPoolManager(poolManager), oracle);
        require(address(hook) == hookAddress, "Deploy: hook address mismatch");
        console2.log("GradientShieldHook:", address(hook));
    }
}
