// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ECDSAServiceManagerBase} from
    "eigenlayer-middleware/src/unaudited/ECDSAServiceManagerBase.sol";
import {ECDSAStakeRegistry} from "eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ScoringOracle} from "./ScoringOracle.sol";

/// @title GradientShieldServiceManager
/// @notice EigenLayer ECDSA-based AVS service manager for GradientShield.
///         Inherits from ECDSAServiceManagerBase (real EigenLayer middleware)
///         and adds MEV score task creation / operator response logic.
/// @dev Operators register through the ECDSAStakeRegistry, which verifies
///      stake via EigenLayer's DelegationManager. Task responses are verified
///      against the operator's registered signing key in the stake registry.
contract GradientShieldServiceManager is ECDSAServiceManagerBase {
    using ECDSA for bytes32;

    // -----------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------

    struct ScoreTask {
        address subject;
        uint32 fromBlock;
        uint32 toBlock;
        uint32 createdBlock;
        bool responded;
    }

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    ScoringOracle public immutable oracle;
    ScoreTask[] public tasks;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event ScoreTaskCreated(uint32 indexed taskId, address indexed subject, uint32 fromBlock, uint32 toBlock);
    event ScoreTaskResponded(uint32 indexed taskId, address indexed subject, uint16 score, address indexed operator);

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error TaskAlreadyResponded();
    error InvalidTaskId();
    error InvalidSignature();
    error InvalidBlockRange();
    error ZeroAddress();
    error OperatorNotRegistered();

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager,
        ScoringOracle _oracle
    )
        ECDSAServiceManagerBase(
            _avsDirectory,
            _stakeRegistry,
            _rewardsCoordinator,
            _delegationManager,
            _allocationManager
        )
    {
        oracle = _oracle;
    }

    function initialize(address initialOwner, address rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, rewardsInitiator);
    }

    // -----------------------------------------------------------------
    // IServiceManager admin stubs (PermissionController + OperatorSets)
    // -----------------------------------------------------------------

    function addPendingAdmin(address) external onlyOwner {}
    function removePendingAdmin(address) external onlyOwner {}
    function removeAdmin(address) external onlyOwner {}
    function setAppointee(address, address, bytes4) external onlyOwner {}
    function removeAppointee(address, address, bytes4) external onlyOwner {}
    function deregisterOperatorFromOperatorSets(address, uint32[] memory) external onlyStakeRegistry {}

    // -----------------------------------------------------------------
    // Task creation
    // -----------------------------------------------------------------

    function createScoreTask(address subject, uint32 fromBlock, uint32 toBlock)
        external
        returns (uint32 taskId)
    {
        if (subject == address(0)) revert ZeroAddress();
        if (fromBlock >= toBlock) revert InvalidBlockRange();

        taskId = uint32(tasks.length);
        tasks.push(
            ScoreTask({
                subject: subject,
                fromBlock: fromBlock,
                toBlock: toBlock,
                createdBlock: uint32(block.number),
                responded: false
            })
        );

        emit ScoreTaskCreated(taskId, subject, fromBlock, toBlock);
    }

    // -----------------------------------------------------------------
    // Task response (operator submits verified score)
    // -----------------------------------------------------------------

    function respondToTask(uint32 taskId, uint16 score, bytes calldata signature) external {
        if (taskId >= tasks.length) revert InvalidTaskId();
        ScoreTask storage task = tasks[taskId];
        if (task.responded) revert TaskAlreadyResponded();

        // Verify the caller is a registered operator in the stake registry
        ECDSAStakeRegistry registry = ECDSAStakeRegistry(stakeRegistry);
        if (!registry.operatorRegistered(msg.sender)) revert OperatorNotRegistered();

        // Build the message the operator should have signed
        bytes32 messageHash = keccak256(abi.encodePacked(taskId, task.subject, score));
        bytes32 ethSignedHash = ECDSA.toEthSignedMessageHash(messageHash);

        // Recover signer and verify it matches the operator's registered signing key
        address signer = ethSignedHash.recover(signature);
        address registeredKey = registry.getLatestOperatorSigningKey(msg.sender);
        if (signer != registeredKey) revert InvalidSignature();

        // Mark responded and write the score
        task.responded = true;
        oracle.setScore(task.subject, score);

        emit ScoreTaskResponded(taskId, task.subject, score, msg.sender);
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    function taskCount() external view returns (uint32) {
        return uint32(tasks.length);
    }

    function getTask(uint32 taskId) external view returns (ScoreTask memory) {
        return tasks[taskId];
    }
}
