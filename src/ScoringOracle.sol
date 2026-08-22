// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ScoringOracle
/// @notice Per-address MEV/bot risk score storage with daily linear decay.
/// @dev SCAFFOLD STUB — signatures and state are laid out; behavioural logic is
///      marked with TODOs. Scores are written by the AVS (EigenLayer operator set)
///      and read by {GradientShieldHook} on every swap.
///
/// Score semantics (0–100):
///   0–39   : clean / unknown           → base fee
///   40–79  : suspicious                 → escalated fee (see GradientShieldHook)
///   80–100 : confirmed toxic flow       → swap rejected
contract ScoringOracle {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct ScoreRecord {
        uint16 score; // 0–100
        uint40 lastUpdated; // block timestamp of last write
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint16 public constant MAX_SCORE = 100;

    /// @notice Points of score shed per full day since {lastUpdated}.
    /// @dev TODO: tune. Linear decay keeps stale scores from permanently
    ///      penalising an address that has stopped its toxic behaviour.
    uint16 public constant DECAY_PER_DAY = 5;

    uint256 internal constant ONE_DAY = 1 days;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Raw, non-decayed score record per address.
    mapping(address => ScoreRecord) internal _records;

    /// @notice Authorised writer — the AVS service manager / operator relay.
    /// @dev TODO: replace single-writer model with EigenLayer ServiceManager
    ///      signature verification (quorum of operator sigs).
    address public avs;

    address public owner;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ScoreUpdated(address indexed subject, uint16 oldScore, uint16 newScore, address indexed writer);
    event AvsUpdated(address indexed oldAvs, address indexed newAvs);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error NotAvs();
    error ScoreOutOfRange(uint16 score);
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAvs() {
        if (msg.sender != avs) revert NotAvs();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address _avs) {
        owner = msg.sender;
        avs = _avs; // may be address(0) initially; set later via setAvs
    }

    // ---------------------------------------------------------------------
    // Writes (AVS-gated)
    // ---------------------------------------------------------------------

    /// @notice Set the absolute score for an address.
    /// @dev TODO: accept operator signatures / task response instead of a bare
    ///      onlyAvs write once wired to EigenLayer.
    function setScore(address subject, uint16 newScore) external onlyAvs {
        if (newScore > MAX_SCORE) revert ScoreOutOfRange(newScore);
        uint16 old = _records[subject].score;
        _records[subject] = ScoreRecord({score: newScore, lastUpdated: uint40(block.timestamp)});
        emit ScoreUpdated(subject, old, newScore, msg.sender);
    }

    /// @notice Increase a score by a delta, saturating at {MAX_SCORE}.
    /// @dev Convenience for the escalation flow (e.g. 60 → 95). Applies decay
    ///      to the current value first so escalation compounds off the live score.
    function bumpScore(address subject, uint16 delta) external onlyAvs returns (uint16 newScore) {
        // TODO: implement — read decayed current score, add delta, clamp to MAX_SCORE,
        //       persist with fresh timestamp, emit ScoreUpdated.
        subject; // silence unused-var warnings until implemented
        delta;
        revert("ScoringOracle: bumpScore not implemented");
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @notice Current, decay-adjusted score for an address.
    /// @dev TODO: implement linear decay:
    ///        daysElapsed = (block.timestamp - lastUpdated) / ONE_DAY
    ///        decayed     = score - min(score, daysElapsed * DECAY_PER_DAY)
    function getScore(address subject) external view returns (uint16) {
        // Placeholder: returns the raw stored score with no decay applied yet.
        return _records[subject].score;
    }

    /// @notice Raw record without decay, for off-chain indexers / debugging.
    function rawRecord(address subject) external view returns (ScoreRecord memory) {
        return _records[subject];
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setAvs(address newAvs) external onlyOwner {
        if (newAvs == address(0)) revert ZeroAddress();
        emit AvsUpdated(avs, newAvs);
        avs = newAvs;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
