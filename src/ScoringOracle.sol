// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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

    /// @notice Authorised writer — the GradientShieldServiceManager contract.
    /// @dev Only the ServiceManager can call setScore/bumpScore. The ServiceManager
    ///      itself verifies operator signatures before writing, so this single-address
    ///      gate is backed by the full operator verification flow.
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

    /// @param _avs The GradientShieldServiceManager contract address. Only this
    ///        address can write scores. Pass address(0) to set it later via setAvs.
    constructor(address _avs) {
        owner = msg.sender;
        avs = _avs;
    }

    // ---------------------------------------------------------------------
    // Writes (AVS-gated)
    // ---------------------------------------------------------------------

    /// @notice Set the absolute score for an address.
    /// @dev Called by the GradientShieldServiceManager after it verifies the
    ///      operator's ECDSA signature on the task response.
    function setScore(address subject, uint16 newScore) external onlyAvs {
        if (newScore > MAX_SCORE) revert ScoreOutOfRange(newScore);
        // saves the old score for the event
        uint16 old = _records[subject].score;
        // block.timestamp will reset the decay clock
        _records[subject] = ScoreRecord({score: newScore, lastUpdated: uint40(block.timestamp)});
        emit ScoreUpdated(subject, old, newScore, msg.sender);
    }

    /// @notice Increase a score by a delta, saturating at {MAX_SCORE}.
    /// @dev Applies decay to the current value first so escalation compounds off
    ///      the live score, not the stale stored value.
    /// delta is if the bot got any other escalations that made the score increase.
    function bumpScore(address subject, uint16 delta) external onlyAvs returns (uint16 newScore) {
        // reads the exact current decay score
        uint16 current = _decayedScore(_records[subject]);
        // fetches the old score from array
        uint16 old = _records[subject].score;
        newScore = current + delta;
        if (newScore > MAX_SCORE) newScore = MAX_SCORE;
        _records[subject] = ScoreRecord({score: newScore, lastUpdated: uint40(block.timestamp)});
        emit ScoreUpdated(subject, old, newScore, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------

    /// @notice Current, decay-adjusted score for an address.
    function getScore(address subject) external view returns (uint16) {
        return _decayedScore(_records[subject]);
    }

    /// @notice Raw record without decay, for off-chain indexers / debugging.
    /// This is for noticing and writing off when it was happened.
    function rawRecord(address subject) external view returns (ScoreRecord memory) {
        return _records[subject];
    }

    /// @notice Linear daily decay: sheds DECAY_PER_DAY per full elapsed day, floored at 0.
    function _decayedScore(ScoreRecord memory rec) internal view returns (uint16) {
        if (rec.score == 0 || rec.lastUpdated == 0) return 0;
        uint256 elapsed = block.timestamp - uint256(rec.lastUpdated);
        uint256 decay = (elapsed / ONE_DAY) * uint256(DECAY_PER_DAY);
        if (decay >= rec.score) return 0;
        return rec.score - uint16(decay);
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
