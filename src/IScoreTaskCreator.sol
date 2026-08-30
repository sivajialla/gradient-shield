// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IScoreTaskCreator
/// @notice Minimal interface for the hook to create scoring tasks on the
///         TaskManager without pulling in BLS/EigenLayer dependencies.
///         This avoids the solc version conflict (v4-core needs 0.8.26,
///         eigenlayer needs ^0.8.27).
interface IScoreTaskCreator {
    function createScoreTask(
        address subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage,
        bytes calldata quorumNumbers
    ) external;

    function taskNumber() external view returns (uint32);
    function latestTaskForSubject(address subject) external view returns (uint32);
}
