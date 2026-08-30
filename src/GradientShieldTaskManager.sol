// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import {Pausable} from "eigenlayer-contracts/src/contracts/permissions/Pausable.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";

import {BLSSignatureChecker} from "eigenlayer-middleware/src/BLSSignatureChecker.sol";
import {OperatorStateRetriever} from "eigenlayer-middleware/src/OperatorStateRetriever.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSSignatureChecker} from "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "eigenlayer-middleware/src/libraries/BN254.sol";

import {ScoringOracle} from "./ScoringOracle.sol";
import {IGradientShieldTaskManager} from "./IGradientShieldTaskManager.sol";

/// @title GradientShieldTaskManager
/// @notice BLS multi-operator quorum task manager for MEV risk scoring.
///         Operators observe on-chain swap patterns off-chain, agree on a score
///         for a target address, and the aggregator submits the BLS-verified
///         consensus score. A challenge window allows disputes before the score
///         becomes final.
///
/// Flow:
///   1. Generator calls createScoreTask (target address + block range).
///   2. Operators sign the scored response off-chain; aggregator aggregates
///      BLS signatures and submits via respondToScoreTask.
///   3. checkSignatures (inherited from BLSSignatureChecker) verifies the
///      aggregated BLS signature against the registered quorum.
///   4. If the quorum threshold is met the score is written to the oracle.
///   5. Within TASK_CHALLENGE_WINDOW_BLOCK anyone can dispute via
///      raiseAndResolveChallenge.
contract GradientShieldTaskManager is
    BLSSignatureChecker,
    OperatorStateRetriever,
    OwnableUpgradeable,
    Pausable,
    IGradientShieldTaskManager
{
    using BN254 for BN254.G1Point;

    // -----------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------

    uint32 public immutable TASK_RESPONSE_WINDOW_BLOCK;
    uint32 public constant TASK_CHALLENGE_WINDOW_BLOCK = 100;
    uint256 internal constant _THRESHOLD_DENOMINATOR = 100;

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    uint32 public latestTaskNum;
    address public aggregator;
    address public generator;
    address public hookAddress;
    ScoringOracle public oracle;

    mapping(uint32 => bytes32) public allTaskHashes;
    mapping(uint32 => bytes32) public allTaskResponses;
    mapping(uint32 => bool) public taskSuccesfullyChallenged;
    mapping(address => uint32) public latestTaskForSubject;

    // -----------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    modifier onlyTaskCreator() {
        if (msg.sender != generator && msg.sender != hookAddress) revert NotGenerator();
        _;
    }

    // -----------------------------------------------------------------
    // Constructor (implementation — disable initializers)
    // -----------------------------------------------------------------

    constructor(
        ISlashingRegistryCoordinator _registryCoordinator,
        IPauserRegistry _pauserRegistry,
        uint32 _taskResponseWindowBlock
    ) BLSSignatureChecker(_registryCoordinator) Pausable(_pauserRegistry) {
        TASK_RESPONSE_WINDOW_BLOCK = _taskResponseWindowBlock;
        _disableInitializers();
    }

    // -----------------------------------------------------------------
    // Initializer (proxy)
    // -----------------------------------------------------------------

    function initialize(
        address _initialOwner,
        address _aggregator,
        address _generator,
        ScoringOracle _oracle
    ) public initializer {
        _transferOwnership(_initialOwner);
        aggregator = _aggregator;
        generator = _generator;
        oracle = _oracle;
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setHookAddress(address _hook) external onlyOwner {
        hookAddress = _hook;
    }

    // -----------------------------------------------------------------
    // Task lifecycle
    // -----------------------------------------------------------------

    /// @notice Creates a scoring task for a target address over a block range.
    ///         The generator (typically an off-chain watcher) calls this when
    ///         suspicious activity is observed.
    function createScoreTask(
        address subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage,
        bytes calldata quorumNumbers
    ) external onlyTaskCreator whenNotPaused {
        ScoreTask memory task = ScoreTask({
            subject: subject,
            fromBlock: fromBlock,
            toBlock: toBlock,
            taskCreatedBlock: uint32(block.number),
            quorumNumbers: quorumNumbers,
            quorumThresholdPercentage: quorumThresholdPercentage
        });

        allTaskHashes[latestTaskNum] = keccak256(abi.encode(task));
        latestTaskForSubject[subject] = latestTaskNum;
        emit ScoreTaskCreated(latestTaskNum, task);
        latestTaskNum++;
    }

    /// @notice Aggregator submits a BLS-verified score response.
    ///         The aggregated signature must satisfy the quorum threshold.
    function respondToScoreTask(
        ScoreTask calldata task,
        ScoreTaskResponse calldata taskResponse,
        IBLSSignatureChecker.NonSignerStakesAndSignature memory nonSignerStakesAndSignature
    ) external onlyAggregator whenNotPaused {
        uint32 taskIndex = taskResponse.referenceTaskIndex;

        if (keccak256(abi.encode(task)) != allTaskHashes[taskIndex]) {
            revert TaskMismatch();
        }
        if (allTaskResponses[taskIndex] != bytes32(0)) {
            revert TaskAlreadyResponded();
        }
        if (uint32(block.number) > task.taskCreatedBlock + TASK_RESPONSE_WINDOW_BLOCK) {
            revert ResponseTooLate();
        }

        bytes32 messageHash = keccak256(abi.encode(taskResponse));

        (IBLSSignatureChecker.QuorumStakeTotals memory quorumStakeTotals, bytes32 hashOfNonSigners) =
            _checkBLSSignatures(messageHash, task.quorumNumbers, task.taskCreatedBlock, nonSignerStakesAndSignature);

        for (uint256 i = 0; i < task.quorumNumbers.length; i++) {
            if (
                uint256(quorumStakeTotals.signedStakeForQuorum[i]) * _THRESHOLD_DENOMINATOR
                    < uint256(quorumStakeTotals.totalStakeForQuorum[i]) * task.quorumThresholdPercentage
            ) {
                revert QuorumNotMet();
            }
        }

        TaskResponseMetadata memory metadata =
            TaskResponseMetadata({taskResponsedBlock: uint32(block.number), hashOfNonSigners: hashOfNonSigners});

        allTaskResponses[taskIndex] = keccak256(abi.encode(taskResponse, metadata));

        oracle.setScore(task.subject, taskResponse.score);

        emit ScoreTaskResponded(taskIndex, taskResponse);
    }

    /// @notice Challenge a task response within the challenge window.
    ///         If the non-signer pubkeys match the recorded hash, the
    ///         challenge succeeds — the score is reset and operators who
    ///         signed the incorrect response can be slashed (slashing logic
    ///         is plugged in via the ServiceManager).
    function raiseAndResolveChallenge(
        ScoreTask calldata task,
        ScoreTaskResponse calldata taskResponse,
        TaskResponseMetadata calldata taskResponseMetadata,
        BN254.G1Point[] memory pubkeysOfNonSigningOperators
    ) external {
        uint32 taskIndex = taskResponse.referenceTaskIndex;

        if (allTaskResponses[taskIndex] == bytes32(0)) {
            revert NotResponded();
        }
        if (allTaskResponses[taskIndex] != keccak256(abi.encode(taskResponse, taskResponseMetadata))) {
            revert ResponseMismatch();
        }
        if (taskSuccesfullyChallenged[taskIndex]) {
            revert AlreadyChallenged();
        }
        if (uint32(block.number) > taskResponseMetadata.taskResponsedBlock + TASK_CHALLENGE_WINDOW_BLOCK) {
            revert ChallengeWindowExpired();
        }

        bytes32[] memory hashesOfPubkeys = new bytes32[](pubkeysOfNonSigningOperators.length);
        for (uint256 i = 0; i < pubkeysOfNonSigningOperators.length; i++) {
            hashesOfPubkeys[i] = pubkeysOfNonSigningOperators[i].hashG1Point();
        }

        bytes32 signatoryRecordHash =
            keccak256(abi.encodePacked(task.taskCreatedBlock, hashesOfPubkeys));

        if (signatoryRecordHash != taskResponseMetadata.hashOfNonSigners) {
            revert NonSignerPubkeysMismatch();
        }

        taskSuccesfullyChallenged[taskIndex] = true;
        oracle.setScore(task.subject, 0);

        emit TaskChallengedSuccessfully(taskIndex, msg.sender);
    }

    // -----------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------

    function taskNumber() external view returns (uint32) {
        return latestTaskNum;
    }

    function getTaskResponseWindowBlock() external view returns (uint32) {
        return TASK_RESPONSE_WINDOW_BLOCK;
    }

    // -----------------------------------------------------------------
    // Internal (virtual for testability)
    // -----------------------------------------------------------------

    /// @dev Wraps checkSignatures so tests can override BLS verification.
    function _checkBLSSignatures(
        bytes32 msgHash,
        bytes calldata quorumNumbers,
        uint32 referenceBlockNumber,
        IBLSSignatureChecker.NonSignerStakesAndSignature memory params
    ) internal virtual returns (IBLSSignatureChecker.QuorumStakeTotals memory, bytes32) {
        return checkSignatures(msgHash, quorumNumbers, referenceBlockNumber, params);
    }
}
