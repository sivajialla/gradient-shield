// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";

import {AVSDirectoryMock} from "eigenlayer-middleware/test/mocks/AVSDirectoryMock.sol";
import {AllocationManagerMock} from "eigenlayer-middleware/test/mocks/AllocationManagerMock.sol";
import {RewardsCoordinatorMock} from "eigenlayer-middleware/test/mocks/RewardsCoordinatorMock.sol";
import {PermissionControllerMock} from "eigenlayer-middleware/test/mocks/PermissionControllerMock.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {GradientShieldTaskManager} from "../src/GradientShieldTaskManager.sol";
import {IGradientShieldTaskManager} from "../src/IGradientShieldTaskManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title DeploySepolia
/// @notice Deploys GradientShield BLS AVS on Sepolia with mocked EigenLayer infra.
///         Mock RegistryCoordinator, StakeRegistry, BLSApkRegistry are created as
///         simple contracts that return the minimum required values for constructor
///         initialization.
///
/// Usage:
///   forge script script/DeploySepolia.s.sol --rpc-url $RPC_URL --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("Deployer:", deployer);
        vm.startBroadcast(pk);

        // Step 1: Deploy mock BLS infrastructure
        address[5] memory mocks = _deployMocks();

        // Step 2: Deploy Oracle + TaskManager + ServiceManager
        _deployAVS(deployer, mocks);

        vm.stopBroadcast();
    }

    function _deployMocks() internal returns (address[5] memory mocks) {
        MockDelegation mockDel = new MockDelegation();
        MockStakeRegistry mockSR = new MockStakeRegistry(address(mockDel));
        MockBLSApkRegistry mockAPK = new MockBLSApkRegistry();
        MockRegistryCoordinator mockRC = new MockRegistryCoordinator(address(mockSR), address(mockAPK));
        MockPauserRegistry mockPR = new MockPauserRegistry();

        mocks[0] = address(mockRC);
        mocks[1] = address(mockSR);
        mocks[2] = address(mockPR);
        mocks[3] = address(new AVSDirectoryMock());
        mocks[4] = address(new AllocationManagerMock());

        console2.log("Mock infra deployed");
    }

    function _deployAVS(address deployer, address[5] memory m) internal {
        ScoringOracle oracle = new ScoringOracle(address(0));
        console2.log("ScoringOracle:", address(oracle));

        RewardsCoordinatorMock rewardsCoord = new RewardsCoordinatorMock();
        PermissionControllerMock permCtrl = new PermissionControllerMock();

        // TaskManager (BLS-verified scoring)
        GradientShieldTaskManager tmImpl = new GradientShieldTaskManager(
            ISlashingRegistryCoordinator(m[0]), IPauserRegistry(m[2]), 100
        );
        ERC1967Proxy tmProxy = new ERC1967Proxy(
            address(tmImpl),
            abi.encodeCall(GradientShieldTaskManager.initialize, (deployer, deployer, deployer, oracle))
        );
        console2.log("TaskManager (proxy):", address(tmProxy));

        // ServiceManager (AVS identity)
        GradientShieldServiceManager smImpl = new GradientShieldServiceManager(
            IAVSDirectory(m[3]),
            IRewardsCoordinator(address(rewardsCoord)),
            ISlashingRegistryCoordinator(m[0]),
            IStakeRegistry(m[1]),
            IPermissionController(address(permCtrl)),
            IAllocationManager(m[4]),
            oracle
        );
        ERC1967Proxy smProxy = new ERC1967Proxy(
            address(smImpl),
            abi.encodeCall(
                GradientShieldServiceManager.initialize,
                (deployer, deployer, IGradientShieldTaskManager(address(tmProxy)))
            )
        );
        console2.log("ServiceManager (proxy):", address(smProxy));

        oracle.setAvs(address(tmProxy));

        console2.log("---");
        console2.log("DEPLOYMENT COMPLETE");
        console2.log("Generator / Aggregator:", deployer);
    }
}

// ---------------------------------------------------------------------------
// Minimal mocks for BLS constructor initialization on Sepolia
// ---------------------------------------------------------------------------

contract MockDelegation {
    // BLSSignatureCheckerStorage calls stakeRegistry.delegation()
}

contract MockStakeRegistry {
    address public immutable delegationAddr;

    constructor(address _delegation) {
        delegationAddr = _delegation;
    }

    function delegation() external view returns (address) {
        return delegationAddr;
    }
}

contract MockBLSApkRegistry {}

contract MockRegistryCoordinator {
    address public immutable stakeRegistryAddr;
    address public immutable blsApkRegistryAddr;

    constructor(address _sr, address _apk) {
        stakeRegistryAddr = _sr;
        blsApkRegistryAddr = _apk;
    }

    function stakeRegistry() external view returns (address) {
        return stakeRegistryAddr;
    }

    function blsApkRegistry() external view returns (address) {
        return blsApkRegistryAddr;
    }

    function quorumCount() external pure returns (uint8) {
        return 0;
    }
}

contract MockPauserRegistry {
    function isPauser(address) external pure returns (bool) {
        return true;
    }

    function unpauser() external pure returns (address) {
        return address(1);
    }
}
