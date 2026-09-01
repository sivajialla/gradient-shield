// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BN254Lib} from "./libraries/BN254Lib.sol";

import {ScoringOracle} from "./ScoringOracle.sol";
import {IScoreTaskCreator} from "./IScoreTaskCreator.sol";

/// @title BLSQuorumTaskManager
/// @notice Self-contained BLS multi-operator quorum for MEV risk scoring.
///
/// This is the *runnable* AVS path. It performs genuine BN254 BLS aggregate
/// signature verification via the pairing precompile, with a real M-of-N
/// quorum threshold — but it keeps its own operator registry instead of
/// depending on EigenLayer's RegistryCoordinator / BLSApkRegistry / StakeRegistry.
/// That makes the whole loop deployable on a bare anvil node or any testnet,
/// which the EigenLayer-coupled {GradientShieldTaskManager} is not.
///
/// The cryptography is identical to EigenLayer's BLSSignatureChecker:
///   • Public keys live in G2, signatures in G1.
///   • Signers are aggregated by summing their G1 keys on-chain (EC-add precompile).
///   • A gamma-randomised pairing simultaneously proves (a) the aggregate
///     signature is valid and (b) apkG1 and apkG2 encode the same key:
///
///       e(σ + γ·apkG1, −g2) · e(H(m) + γ·g1, apkG2) == 1
///
/// The difference from the production TaskManager is *who decides the quorum*:
/// here it is a registered operator set with equal weight; in EigenLayer it is
/// restaking weight read from the StakeRegistry.
///
/// Flow:
///   1. Owner registers operators with their (pkG1, pkG2) BLS keys.
///   2. The hook (or generator) calls createScoreTask on detection.
///   3. Operators sign keccak256(taskIndex, subject, score) off-chain in G1.
///   4. The aggregator sums the signatures and calls respondToScoreTask with
///      the signer set, the aggregate G2 key, and the aggregate signature.
///   5. On a valid pairing + met quorum, the score is written to the oracle.
contract BLSQuorumTaskManager is IScoreTaskCreator {
    using BN254Lib for BN254Lib.G1Point;

    // -----------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------

    struct Operator {
        BN254Lib.G1Point pkG1;
        BN254Lib.G2Point pkG2;
        bool registered;
    }

    struct ScoreTask {
        address subject;
        uint256 fromBlock;
        uint256 toBlock;
        uint32 createdBlock;
        uint32 quorumThresholdPercentage;
        bool responded;
        uint16 score;
    }

    // -----------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------

    /// @notice Blocks the aggregator has to respond before a task expires.
    uint32 public constant TASK_RESPONSE_WINDOW_BLOCK = 100;

    uint256 internal constant _THRESHOLD_DENOMINATOR = 100;

    /// @dev Gas forwarded to the pairing precompile, matching EigenLayer.
    uint256 internal constant _PAIRING_GAS = 120_000;

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    address public owner;
    address public aggregator;
    address public generator;
    address public hookAddress;
    ScoringOracle public immutable oracle;

    uint32 public latestTaskNum;
    mapping(uint32 => ScoreTask) public tasks;
    mapping(address => uint32) public latestTaskForSubject;

    address[] public operatorList;
    mapping(address => Operator) internal _operators;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

    event OperatorRegistered(address indexed operator, uint256 operatorCount);
    event OperatorDeregistered(address indexed operator, uint256 operatorCount);
    event ScoreTaskCreated(
        uint32 indexed taskIndex,
        address indexed subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage
    );
    event ScoreTaskResponded(
        uint32 indexed taskIndex,
        address indexed subject,
        uint16 score,
        uint256 signerCount,
        uint256 operatorCount
    );

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error NotOwner();
    error NotAggregator();
    error NotTaskCreator();
    error AlreadyRegistered();
    error NotRegistered();
    error NoOperators();
    error TaskDoesNotExist();
    error TaskAlreadyResponded();
    error ResponseTooLate();
    error QuorumNotMet(uint256 signers, uint256 required);
    error SignersNotSorted();
    error InvalidBLSPairing();
    error InvalidBLSSignature();
    error ScoreOutOfRange();
    error ZeroAddress();

    // -----------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAggregator() {
        if (msg.sender != aggregator) revert NotAggregator();
        _;
    }

    modifier onlyTaskCreator() {
        if (msg.sender != generator && msg.sender != hookAddress) revert NotTaskCreator();
        _;
    }

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(ScoringOracle _oracle, address _aggregator, address _generator) {
        if (address(_oracle) == address(0)) revert ZeroAddress();
        owner = msg.sender;
        oracle = _oracle;
        aggregator = _aggregator;
        generator = _generator;
    }

    // -----------------------------------------------------------------
    // Operator registry
    // -----------------------------------------------------------------

    /// @notice Register an operator's BLS keypair.
    /// @param pkG1 The operator's public key in G1 — summed on-chain to form apkG1.
    /// @param pkG2 The operator's public key in G2 — used in the pairing.
    /// @dev Consistency between pkG1 and pkG2 is enforced at response time by
    ///      the gamma term of the pairing equation, so a mismatched pair simply
    ///      cannot produce a verifying aggregate signature.
    function registerOperator(address operator, BN254Lib.G1Point calldata pkG1, BN254Lib.G2Point calldata pkG2)
        external
        onlyOwner
    {
        if (operator == address(0)) revert ZeroAddress();
        if (_operators[operator].registered) revert AlreadyRegistered();

        _operators[operator] = Operator({pkG1: pkG1, pkG2: pkG2, registered: true});
        operatorList.push(operator);

        emit OperatorRegistered(operator, operatorList.length);
    }

    function deregisterOperator(address operator) external onlyOwner {
        if (!_operators[operator].registered) revert NotRegistered();

        delete _operators[operator];
        uint256 len = operatorList.length;
        for (uint256 i = 0; i < len; i++) {
            if (operatorList[i] == operator) {
                operatorList[i] = operatorList[len - 1];
                operatorList.pop();
                break;
            }
        }

        emit OperatorDeregistered(operator, operatorList.length);
    }

    function operatorCount() public view returns (uint256) {
        return operatorList.length;
    }

    function getOperator(address operator) external view returns (Operator memory) {
        return _operators[operator];
    }

    // -----------------------------------------------------------------
    // Task lifecycle
    // -----------------------------------------------------------------

    /// @inheritdoc IScoreTaskCreator
    /// @dev `quorumNumbers` is accepted for interface compatibility with the
    ///      EigenLayer TaskManager but is unused here — this quorum is the
    ///      single registered operator set.
    function createScoreTask(
        address subject,
        uint256 fromBlock,
        uint256 toBlock,
        uint32 quorumThresholdPercentage,
        bytes calldata
    ) external onlyTaskCreator {
        if (operatorList.length == 0) revert NoOperators();

        uint32 taskIndex = latestTaskNum;
        tasks[taskIndex] = ScoreTask({
            subject: subject,
            fromBlock: fromBlock,
            toBlock: toBlock,
            createdBlock: uint32(block.number),
            quorumThresholdPercentage: quorumThresholdPercentage,
            responded: false,
            score: 0
        });
        latestTaskForSubject[subject] = taskIndex;
        latestTaskNum = taskIndex + 1;

        emit ScoreTaskCreated(taskIndex, subject, fromBlock, toBlock, quorumThresholdPercentage);
    }

    /// @notice Submit the quorum's BLS-signed verdict for a task.
    /// @param taskIndex   Task being answered.
    /// @param score       Agreed risk score (0–100).
    /// @param signerIdxs  Indices into {operatorList} of the operators that
    ///                    signed. Must be strictly increasing (no duplicates).
    /// @param apkG2       Aggregate G2 public key of exactly those signers.
    /// @param sigma       Aggregate G1 signature over {scoreMessageHash}.
    function respondToScoreTask(
        uint32 taskIndex,
        uint16 score,
        uint256[] calldata signerIdxs,
        BN254Lib.G2Point calldata apkG2,
        BN254Lib.G1Point calldata sigma
    ) external onlyAggregator {
        ScoreTask storage task = tasks[taskIndex];

        if (task.createdBlock == 0) revert TaskDoesNotExist();
        if (task.responded) revert TaskAlreadyResponded();
        if (uint32(block.number) > task.createdBlock + TASK_RESPONSE_WINDOW_BLOCK) revert ResponseTooLate();
        if (score > oracle.MAX_SCORE()) revert ScoreOutOfRange();

        // --- Quorum threshold (equal weight per operator) ---
        uint256 total = operatorList.length;
        uint256 signers = signerIdxs.length;
        if (signers * _THRESHOLD_DENOMINATOR < total * task.quorumThresholdPercentage) {
            revert QuorumNotMet(signers, (total * task.quorumThresholdPercentage + 99) / _THRESHOLD_DENOMINATOR);
        }

        // --- Aggregate the signers' G1 keys on-chain ---
        BN254Lib.G1Point memory apkG1 = _aggregatePubkeys(signerIdxs);

        // --- Verify the aggregate BLS signature ---
        bytes32 msgHash = scoreMessageHash(taskIndex, task.subject, score);
        (bool pairingOk, bool sigOk) = verifySignature(msgHash, apkG1, apkG2, sigma);
        if (!pairingOk) revert InvalidBLSPairing();
        if (!sigOk) revert InvalidBLSSignature();

        // --- Commit ---
        task.responded = true;
        task.score = score;
        oracle.setScore(task.subject, score);

        emit ScoreTaskResponded(taskIndex, task.subject, score, signers, total);
    }

    // -----------------------------------------------------------------
    // BLS verification
    // -----------------------------------------------------------------

    /// @notice The digest each operator signs for a task verdict.
    function scoreMessageHash(uint32 taskIndex, address subject, uint16 score) public pure returns (bytes32) {
        return keccak256(abi.encode(taskIndex, subject, score));
    }

    /// @dev Sums the G1 public keys of the given signer indices. Indices must be
    ///      strictly increasing, which rejects duplicates that would otherwise
    ///      let one operator be counted many times toward the quorum.
    function _aggregatePubkeys(uint256[] calldata signerIdxs) internal view returns (BN254Lib.G1Point memory apkG1) {
        uint256 len = signerIdxs.length;
        if (len == 0) revert QuorumNotMet(0, 1);

        uint256 total = operatorList.length;
        uint256 prev = type(uint256).max;

        for (uint256 i = 0; i < len; i++) {
            uint256 idx = signerIdxs[i];
            if (idx >= total) revert NotRegistered();
            if (i != 0 && idx <= prev) revert SignersNotSorted();
            prev = idx;

            BN254Lib.G1Point memory pk = _operators[operatorList[idx]].pkG1;
            apkG1 = i == 0 ? pk : apkG1.plus(pk);
        }
    }

    /// @notice Gamma-randomised pairing check. Proves in one pairing that the
    ///         aggregate signature is valid AND that apkG1 matches apkG2.
    /// @dev    e(σ + γ·apkG1, −g2) · e(H(m) + γ·g1, apkG2) == 1
    ///         Identical construction to EigenLayer's
    ///         BLSSignatureChecker.trySignatureAndApkVerification.
    function verifySignature(
        bytes32 msgHash,
        BN254Lib.G1Point memory apkG1,
        BN254Lib.G2Point memory apkG2,
        BN254Lib.G1Point memory sigma
    ) public view returns (bool pairingSuccessful, bool signatureIsValid) {
        uint256 gamma = uint256(
            keccak256(
                abi.encodePacked(
                    msgHash,
                    apkG1.X,
                    apkG1.Y,
                    apkG2.X[0],
                    apkG2.X[1],
                    apkG2.Y[0],
                    apkG2.Y[1],
                    sigma.X,
                    sigma.Y
                )
            )
        ) % BN254Lib.FR_MODULUS;

        return BN254Lib.safePairing(
            sigma.plus(apkG1.scalar_mul(gamma)),
            BN254Lib.negGeneratorG2(),
            BN254Lib.hashToG1(msgHash).plus(BN254Lib.generatorG1().scalar_mul(gamma)),
            apkG2,
            _PAIRING_GAS
        );
    }

    // -----------------------------------------------------------------
    // Views (IScoreTaskCreator)
    // -----------------------------------------------------------------

    function taskNumber() external view returns (uint32) {
        return latestTaskNum;
    }

    function getTask(uint32 taskIndex) external view returns (ScoreTask memory) {
        return tasks[taskIndex];
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function setHookAddress(address _hook) external onlyOwner {
        hookAddress = _hook;
    }

    function setAggregator(address _aggregator) external onlyOwner {
        aggregator = _aggregator;
    }

    function setGenerator(address _generator) external onlyOwner {
        generator = _generator;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
