// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title ScoringOracleTest
/// @notice Tests the {ScoringOracle} in isolation — score storage, daily decay,
///         escalation bumps, and AVS/owner access control. How those scores drive the
///         hook is covered by {HookBehaviorTest} and {MEVAttackDefenseTest}.
/// @dev SCAFFOLD STUB — decay and bumpScore are not implemented yet, so the tests that
///      exercise them are skipped.
contract ScoringOracleTest is Test {
    ScoringOracle internal oracle;

    address internal avs = address(0xA75);
    address internal constant SUBJECT = address(0xB07);

    function setUp() public {
        oracle = new ScoringOracle(avs);
    }

    // ---------------------------------------------------------------------
    // Writes & access control
    // ---------------------------------------------------------------------

    /// @notice The AVS can set a score; a non-AVS caller is rejected.
    function test_onlyAvsCanSetScore() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 60);
        assertEq(oracle.getScore(SUBJECT), 60);

        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(SUBJECT, 10);
    }

    /// @notice Scores above MAX_SCORE are rejected.
    function test_setScoreRejectsOutOfRange() public {
        vm.prank(avs);
        vm.expectRevert(abi.encodeWithSelector(ScoringOracle.ScoreOutOfRange.selector, 101));
        oracle.setScore(SUBJECT, 101);
    }

    // ---------------------------------------------------------------------
    // Decay
    // ---------------------------------------------------------------------

    /// @notice Score sheds DECAY_PER_DAY points per elapsed day and never underflows.
    function test_scoreDecaysOverTime() public {
        // TODO: implement decay in ScoringOracle.getScore first, then:
        //   vm.prank(avs); oracle.setScore(SUBJECT, 50);
        //   vm.warp(block.timestamp + 3 days);
        //   assertEq(oracle.getScore(SUBJECT), 50 - 3 * oracle.DECAY_PER_DAY());
        vm.skip(true);
    }

    // ---------------------------------------------------------------------
    // Escalation
    // ---------------------------------------------------------------------

    /// @notice bumpScore adds to the live (decayed) score and saturates at MAX_SCORE.
    function test_bumpScoreSaturatesAtMax() public {
        // TODO: implement bumpScore first, then assert 60 -> bump 50 -> clamps to 100.
        vm.skip(true);
    }
}
