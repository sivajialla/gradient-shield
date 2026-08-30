// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BN254} from "eigenlayer-middleware/src/libraries/BN254.sol";
import {IBLSSignatureChecker} from "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";

interface IGradientShieldTaskManager {
    // -----------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------

    struct ScoreTask {
        address subject;
        uint256 fromBlock;
        uint256 toBlock;
        uint32 taskCreatedBlock;
        bytes quorumNumbers;
        uint32 quorumThresholdPercentage;
    }

    struct ScoreTaskResponse {
        uint32 referenceTaskIndex;
        uint16 score;
    }

    struct TaskResponseMetadata {
        uint32 taskResponsedBlock;
        bytes32 hashOfNonSigners;
    }

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event ScoreTaskCreated(uint32 indexed taskIndex, ScoreTask task);
    event ScoreTaskResponded(uint32 indexed taskIndex, ScoreTaskResponse response);
    event TaskChallengedSuccessfully(uint32 indexed taskIndex, address challenger);
    event TaskChallengedUnsuccessfully(uint32 indexed taskIndex, address challenger);

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error TaskMismatch();
    error TaskAlreadyResponded();
    error ResponseTooLate();
    error QuorumNotMet();
    error NotAggregator();
    error NotGenerator();
    error NotResponded();
    error ResponseMismatch();
    error AlreadyChallenged();
    error ChallengeWindowExpired();
    error NonSignerPubkeysMismatch();

    // -----------------------------------------------------------------
    // Functions
    // -----------------------------------------------------------------

    function createScoreTask(
        address subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage,
        bytes calldata quorumNumbers
    ) external;

    function respondToScoreTask(
        ScoreTask calldata task,
        ScoreTaskResponse calldata taskResponse,
        IBLSSignatureChecker.NonSignerStakesAndSignature memory nonSignerStakesAndSignature
    ) external;

    function raiseAndResolveChallenge(
        ScoreTask calldata task,
        ScoreTaskResponse calldata taskResponse,
        TaskResponseMetadata calldata taskResponseMetadata,
        BN254.G1Point[] memory pubkeysOfNonSigningOperators
    ) external;

    function setHookAddress(address _hook) external;

    function taskNumber() external view returns (uint32);
    function getTaskResponseWindowBlock() external view returns (uint32);
    function latestTaskForSubject(address subject) external view returns (uint32);
}
