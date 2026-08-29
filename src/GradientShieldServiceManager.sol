// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ServiceManagerBase} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";

import {ScoringOracle} from "./ScoringOracle.sol";
import {IGradientShieldTaskManager} from "./IGradientShieldTaskManager.sol";

/// @title GradientShieldServiceManager
/// @notice EigenLayer BLS-based AVS service manager for GradientShield.
///         Extends ServiceManagerBase (BLS variant) and links to the
///         GradientShieldTaskManager which handles BLS-verified score tasks.
///
///         Operator registration, BLS key management, and quorum configuration
///         are handled by the SlashingRegistryCoordinator; this contract provides
///         the AVS identity layer (metadata, rewards, operator set management).
contract GradientShieldServiceManager is ServiceManagerBase {
    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    ScoringOracle public immutable oracle;
    IGradientShieldTaskManager public taskManager;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event TaskManagerUpdated(address indexed oldTaskManager, address indexed newTaskManager);

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error ZeroAddress();

    // -----------------------------------------------------------------
    // Constructor (implementation — disable initializers via base)
    // -----------------------------------------------------------------

    constructor(
        IAVSDirectory _avsDirectory,
        IRewardsCoordinator _rewardsCoordinator,
        ISlashingRegistryCoordinator _registryCoordinator,
        IStakeRegistry _stakeRegistry,
        IPermissionController _permissionController,
        IAllocationManager _allocationManager,
        ScoringOracle _oracle
    )
        ServiceManagerBase(
            _avsDirectory,
            _rewardsCoordinator,
            _registryCoordinator,
            _stakeRegistry,
            _permissionController,
            _allocationManager
        )
    {
        oracle = _oracle;
    }

    // -----------------------------------------------------------------
    // Initializer (proxy)
    // -----------------------------------------------------------------

    function initialize(
        address initialOwner,
        address rewardsInitiator,
        IGradientShieldTaskManager _taskManager
    ) external initializer {
        __ServiceManagerBase_init(initialOwner, rewardsInitiator);
        taskManager = _taskManager;
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setTaskManager(IGradientShieldTaskManager _taskManager) external onlyOwner {
        if (address(_taskManager) == address(0)) revert ZeroAddress();
        emit TaskManagerUpdated(address(taskManager), address(_taskManager));
        taskManager = _taskManager;
    }
}
