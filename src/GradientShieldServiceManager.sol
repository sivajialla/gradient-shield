// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ScoringOracle} from "./ScoringOracle.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title GradientShieldServiceManager
/// @notice Simplified EigenLayer AVS service manager for GradientShield.
///         Manages operator registration, score task creation, and verified
///         score submission to the ScoringOracle.
/// @dev This follows the EigenLayer ServiceManager pattern (task creation →
///      operator response → signature verification → state update) but uses
///      plain ECDSA instead of BLS aggregation for demo simplicity.
///      In production, this would inherit from EigenLayer's ServiceManagerBase
///      and use BLSSignatureChecker for multi-operator quorum verification.
contract GradientShieldServiceManager {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // -----------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------

    struct ScoreTask {
        address subject; // address being scored
        uint32 fromBlock; // start of the observation window
        uint32 toBlock; // end of the observation window
        uint32 createdBlock; // block when the task was created
        bool responded; // whether a valid response has been submitted
    }

    struct Operator {
        bool registered;
        address signingKey; // the key the operator signs responses with
    }

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    ScoringOracle public immutable oracle;
    address public owner;

    mapping(address => Operator) public operators;
    uint32 public operatorCount;

    ScoreTask[] public tasks;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event OperatorRegistered(address indexed operator, address signingKey);
    event OperatorDeregistered(address indexed operator);
    event ScoreTaskCreated(uint32 indexed taskId, address indexed subject, uint32 fromBlock, uint32 toBlock);
    event ScoreTaskResponded(uint32 indexed taskId, address indexed subject, uint16 score, address indexed operator);

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error NotOwner();
    error AlreadyRegistered();
    error NotRegistered();
    error TaskAlreadyResponded();
    error InvalidTaskId();
    error InvalidSignature();
    error InvalidBlockRange();
    error ZeroAddress();

    // -----------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(ScoringOracle _oracle) {
        oracle = _oracle;
        owner = msg.sender;
    }

    // -----------------------------------------------------------------
    // Operator management
    // -----------------------------------------------------------------

    /// @notice Register as an operator for this AVS.
    /// @param signingKey The ECDSA key the operator will sign responses with.
    ///        Can be the same as msg.sender or a separate hot key.
    /// @dev In production, this would go through EigenLayer's RegistryCoordinator
    ///      which checks the operator is registered with the DelegationManager
    ///      and has sufficient stake.
    function registerOperator(address signingKey) external {
        if (signingKey == address(0)) revert ZeroAddress();
        if (operators[msg.sender].registered) revert AlreadyRegistered();

        operators[msg.sender] = Operator({registered: true, signingKey: signingKey});
        operatorCount++;
        emit OperatorRegistered(msg.sender, signingKey);
    }

    /// @notice Deregister an operator.
    function deregisterOperator() external {
        if (!operators[msg.sender].registered) revert NotRegistered();
        delete operators[msg.sender];
        operatorCount--;
        emit OperatorDeregistered(msg.sender);
    }

    // -----------------------------------------------------------------
    // Task creation
    // -----------------------------------------------------------------

    /// @notice Create a new score task. Anyone can create tasks — the AVS
    ///         task creator (off-chain) or the owner would typically do this
    ///         on a cadence (e.g. every N blocks for flagged addresses).
    /// @param subject The address to score.
    /// @param fromBlock Start of the observation window.
    /// @param toBlock End of the observation window.
    function createScoreTask(address subject, uint32 fromBlock, uint32 toBlock) external returns (uint32 taskId) {
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

    /// @notice Submit a signed score for a task.
    /// @param taskId The task to respond to.
    /// @param score The computed MEV risk score (0–100).
    /// @param signature ECDSA signature over keccak256(taskId, subject, score)
    ///        signed by the operator's registered signing key.
    /// @dev The flow:
    ///   1. Check the task exists and hasn't been responded to.
    ///   2. Recover the signer from the signature.
    ///   3. Find the operator whose signingKey matches.
    ///   4. If valid → call oracle.setScore(subject, score).
    ///
    ///   In production with BLS + quorum:
    ///   - Multiple operators sign independently.
    ///   - An aggregator bundles signatures into one aggregated BLS sig.
    ///   - This function checks the aggregated sig against the quorum threshold.
    ///   - Only if quorum is met does the score get written.
    function respondToTask(uint32 taskId, uint16 score, bytes calldata signature) external {
        if (taskId >= tasks.length) revert InvalidTaskId();
        ScoreTask storage task = tasks[taskId];
        if (task.responded) revert TaskAlreadyResponded();

        // Build the message the operator should have signed
        bytes32 messageHash = keccak256(abi.encodePacked(taskId, task.subject, score));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();

        // Recover signer
        address signer = ethSignedHash.recover(signature);

        // Verify the signer is a registered operator's signing key
        address operatorAddr = msg.sender;
        if (!operators[operatorAddr].registered) revert NotRegistered();
        if (operators[operatorAddr].signingKey != signer) revert InvalidSignature();

        // Mark responded and write the score
        task.responded = true;
        oracle.setScore(task.subject, score);

        emit ScoreTaskResponded(taskId, task.subject, score, operatorAddr);
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
