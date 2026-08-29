// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ECDSAStakeRegistry} from "eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {IECDSAStakeRegistryTypes} from "eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import {ISignatureUtilsMixinTypes} from
    "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtilsMixin.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {DelegationMock} from "eigenlayer-middleware/test/mocks/DelegationMock.sol";
import {AVSDirectoryMock} from "eigenlayer-middleware/test/mocks/AVSDirectoryMock.sol";
import {AllocationManagerMock} from "eigenlayer-middleware/test/mocks/AllocationManagerMock.sol";
import {RewardsCoordinatorMock} from "eigenlayer-middleware/test/mocks/RewardsCoordinatorMock.sol";
import {ERC20Mock} from "eigenlayer-middleware/test/mocks/ERC20Mock.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title DeploySepolia
/// @notice Deploys GradientShield AVS on Sepolia with mocked EigenLayer infra.
///         No real staking needed — mock contracts simulate the EigenLayer layer.
///         The deployer's address is auto-registered as an operator.
///
/// Usage:
///   forge script script/DeploySepolia.s.sol --rpc-url $RPC_URL --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);

        vm.startBroadcast(pk);

        // Step 1: EigenLayer mocks + StakeRegistry
        (ECDSAStakeRegistry stakeRegistry, DelegationMock delegation, address[4] memory mockAddrs) =
            _deployMocks();

        // Step 2: Oracle + ServiceManager
        (ScoringOracle oracle, GradientShieldServiceManager sm) =
            _deployAVS(deployer, stakeRegistry, mockAddrs);

        // Step 3: Wire + register operator
        _wireAndRegister(deployer, oracle, sm, stakeRegistry, delegation, IStrategy(mockAddrs[3]));

        vm.stopBroadcast();
    }

    function _deployMocks()
        internal
        returns (ECDSAStakeRegistry stakeRegistry, DelegationMock delegation, address[4] memory addrs)
    {
        delegation = new DelegationMock();
        AVSDirectoryMock avsDir = new AVSDirectoryMock();
        AllocationManagerMock allocMgr = new AllocationManagerMock();
        RewardsCoordinatorMock rewards = new RewardsCoordinatorMock();
        ERC20Mock mockToken = new ERC20Mock();

        stakeRegistry = new ECDSAStakeRegistry(IDelegationManager(address(delegation)));

        addrs = [address(avsDir), address(rewards), address(allocMgr), address(mockToken)];

        console2.log("DelegationMock:", address(delegation));
        console2.log("ECDSAStakeRegistry:", address(stakeRegistry));
    }

    function _deployAVS(
        address deployer,
        ECDSAStakeRegistry stakeRegistry,
        address[4] memory mockAddrs
    ) internal returns (ScoringOracle oracle, GradientShieldServiceManager sm) {
        oracle = new ScoringOracle(address(0));
        console2.log("ScoringOracle:", address(oracle));

        GradientShieldServiceManager impl = new GradientShieldServiceManager(
            mockAddrs[0], // avsDirectory
            address(stakeRegistry),
            mockAddrs[1], // rewardsCoordinator
            address(0), // delegationManager (accessed via stakeRegistry)
            mockAddrs[2], // allocationManager
            oracle
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GradientShieldServiceManager.initialize, (deployer, deployer))
        );
        sm = GradientShieldServiceManager(address(proxy));
        console2.log("ServiceManager:", address(sm));
    }

    function _wireAndRegister(
        address deployer,
        ScoringOracle oracle,
        GradientShieldServiceManager sm,
        ECDSAStakeRegistry stakeRegistry,
        DelegationMock delegation,
        IStrategy mockStrategy
    ) internal {
        // Initialize quorum
        IECDSAStakeRegistryTypes.StrategyParams[] memory sp =
            new IECDSAStakeRegistryTypes.StrategyParams[](1);
        sp[0] = IECDSAStakeRegistryTypes.StrategyParams({strategy: mockStrategy, multiplier: 10_000});
        stakeRegistry.initialize(
            address(sm), 0, IECDSAStakeRegistryTypes.Quorum({strategies: sp})
        );

        oracle.setAvs(address(sm));

        // Give deployer mock stake and register as operator
        delegation.setIsOperator(deployer, true);
        delegation.setOperatorShares(deployer, mockStrategy, 1000 ether);

        ISignatureUtilsMixinTypes.SignatureWithSaltAndExpiry memory emptySig;
        emptySig.expiry = type(uint256).max;
        stakeRegistry.registerOperatorWithSignature(emptySig, deployer);

        console2.log("---");
        console2.log("Operator registered:", deployer);
        console2.log("DEPLOYMENT COMPLETE - save addresses in operator/.env");
    }
}
