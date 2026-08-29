// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {IGradientShieldTaskManager} from "../src/IGradientShieldTaskManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";

import {AVSDirectoryMock} from "eigenlayer-middleware/test/mocks/AVSDirectoryMock.sol";
import {AllocationManagerMock} from "eigenlayer-middleware/test/mocks/AllocationManagerMock.sol";
import {RewardsCoordinatorMock} from "eigenlayer-middleware/test/mocks/RewardsCoordinatorMock.sol";
import {PermissionControllerMock} from "eigenlayer-middleware/test/mocks/PermissionControllerMock.sol";

contract ServiceManagerTest is Test {
    GradientShieldServiceManager internal sm;
    ScoringOracle internal oracle;

    address internal deployer = address(0xDEAD);
    address internal rewardsInit = address(0x4E47);

    function setUp() public {
        AVSDirectoryMock avsDir = new AVSDirectoryMock();
        AllocationManagerMock allocMgr = new AllocationManagerMock();
        RewardsCoordinatorMock rewardsCoord = new RewardsCoordinatorMock();
        PermissionControllerMock permCtrl = new PermissionControllerMock();

        address mockRC = address(0xC0C0);
        address mockSR = address(0x5757);

        // Mock quorumCount for ServiceManagerBase.getRestakeableStrategies
        vm.mockCall(mockRC, abi.encodeWithSignature("quorumCount()"), abi.encode(uint8(0)));

        oracle = new ScoringOracle(address(0));

        GradientShieldServiceManager impl = new GradientShieldServiceManager(
            IAVSDirectory(address(avsDir)),
            IRewardsCoordinator(address(rewardsCoord)),
            ISlashingRegistryCoordinator(mockRC),
            IStakeRegistry(mockSR),
            IPermissionController(address(permCtrl)),
            IAllocationManager(address(allocMgr)),
            oracle
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GradientShieldServiceManager.initialize,
                (deployer, rewardsInit, IGradientShieldTaskManager(address(0x7A54)))
            )
        );
        sm = GradientShieldServiceManager(address(proxy));
    }

    // -----------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------

    function test_ownerIsSet() public view {
        assertEq(sm.owner(), deployer);
    }

    function test_oracleIsSet() public view {
        assertEq(address(sm.oracle()), address(oracle));
    }

    function test_taskManagerIsSet() public view {
        assertEq(address(sm.taskManager()), address(0x7A54));
    }

    // -----------------------------------------------------------------
    // Admin: setTaskManager
    // -----------------------------------------------------------------

    function test_setTaskManager() public {
        address newTM = address(0xBEEF);
        vm.prank(deployer);
        sm.setTaskManager(IGradientShieldTaskManager(newTM));
        assertEq(address(sm.taskManager()), newTM);
    }

    function test_setTaskManagerEmitsEvent() public {
        address newTM = address(0xBEEF);
        vm.expectEmit(true, true, false, false);
        emit GradientShieldServiceManager.TaskManagerUpdated(address(0x7A54), newTM);
        vm.prank(deployer);
        sm.setTaskManager(IGradientShieldTaskManager(newTM));
    }

    function test_setTaskManagerRejectsZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(GradientShieldServiceManager.ZeroAddress.selector);
        sm.setTaskManager(IGradientShieldTaskManager(address(0)));
    }

    function test_onlyOwnerCanSetTaskManager() public {
        vm.expectRevert();
        sm.setTaskManager(IGradientShieldTaskManager(address(0xBEEF)));
    }

    // -----------------------------------------------------------------
    // Cannot re-initialize
    // -----------------------------------------------------------------

    function test_cannotReinitialize() public {
        vm.expectRevert();
        sm.initialize(deployer, rewardsInit, IGradientShieldTaskManager(address(0)));
    }
}
