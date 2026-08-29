// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title ScoringOracleTest
/// @notice Tests the {ScoringOracle} in isolation — score storage, daily decay,
///         escalation bumps, and AVS/owner access control.
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

    function test_onlyAvsCanSetScore() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 60);
        assertEq(oracle.getScore(SUBJECT), 60);

        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(SUBJECT, 10);
    }

    function test_setScoreRejectsOutOfRange() public {
        vm.prank(avs);
        vm.expectRevert(abi.encodeWithSelector(ScoringOracle.ScoreOutOfRange.selector, 101));
        oracle.setScore(SUBJECT, 101);
    }

    function test_setScoreEmitsEvent() public {
        vm.prank(avs);
        vm.expectEmit(true, true, false, true);
        emit ScoringOracle.ScoreUpdated(SUBJECT, 0, 60, avs);
        oracle.setScore(SUBJECT, 60);
    }

    // ---------------------------------------------------------------------
    // Decay
    // ---------------------------------------------------------------------

    function test_scoreDecaysOverTime() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 50);
        assertEq(oracle.getScore(SUBJECT), 50);

        // Warp 3 days → should decay by 3 × 5 = 15
        vm.warp(block.timestamp + 3 days);
        assertEq(oracle.getScore(SUBJECT), 35);

        // Raw record still holds the original value
        assertEq(oracle.rawRecord(SUBJECT).score, 50);
    }

    function test_decayFloorsAtZero() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 20);

        // Warp 10 days → decay = 50, but score is only 20 → should floor at 0
        vm.warp(block.timestamp + 10 days);
        assertEq(oracle.getScore(SUBJECT), 0);
    }

    function test_noDecayWithinOneDay() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 80);

        // Warp 23 hours — less than 1 full day, no decay
        vm.warp(block.timestamp + 23 hours);
        assertEq(oracle.getScore(SUBJECT), 80);
    }

    function test_decayIsPerFullDay() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 30);

        // Warp 2 days + 12 hours → only 2 full days of decay = 10
        vm.warp(block.timestamp + 2 days + 12 hours);
        assertEq(oracle.getScore(SUBJECT), 20);
    }

    function test_unsetAddressReturnsZero() public view {
        assertEq(oracle.getScore(address(0xDEAD)), 0);
    }

    // ---------------------------------------------------------------------
    // Escalation (bumpScore)
    // ---------------------------------------------------------------------

    function test_bumpScoreAddsToDecayedValue() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 50);

        // Warp 2 days → decayed = 50 - 10 = 40
        vm.warp(block.timestamp + 2 days);
        assertEq(oracle.getScore(SUBJECT), 40);

        // Bump by 30 → 40 + 30 = 70
        vm.prank(avs);
        uint16 newScore = oracle.bumpScore(SUBJECT, 30);
        assertEq(newScore, 70);
        assertEq(oracle.getScore(SUBJECT), 70);
    }

    function test_bumpScoreSaturatesAtMax() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 60);

        // Bump by 50 → 60 + 50 = 110, clamped to 100
        vm.prank(avs);
        uint16 newScore = oracle.bumpScore(SUBJECT, 50);
        assertEq(newScore, 100);
        assertEq(oracle.getScore(SUBJECT), 100);
    }

    function test_bumpScoreResetsDecayTimer() public {
        vm.prank(avs);
        oracle.setScore(SUBJECT, 50);

        // Warp 4 days → decayed = 50 - 20 = 30
        vm.warp(block.timestamp + 4 days);
        assertEq(oracle.getScore(SUBJECT), 30);

        // Bump by 10 → 30 + 10 = 40, and timestamp resets
        vm.prank(avs);
        oracle.bumpScore(SUBJECT, 10);
        assertEq(oracle.getScore(SUBJECT), 40);

        // Warp another 1 day → decay from the *new* timestamp = 5
        vm.warp(block.timestamp + 1 days);
        assertEq(oracle.getScore(SUBJECT), 35);
    }

    function test_bumpScoreOnlyAvs() public {
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.bumpScore(SUBJECT, 10);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function test_setAvs() public {
        address newAvs = address(0xBEEF);
        oracle.setAvs(newAvs);
        assertEq(oracle.avs(), newAvs);

        // Old AVS can no longer write
        vm.prank(avs);
        vm.expectRevert(ScoringOracle.NotAvs.selector);
        oracle.setScore(SUBJECT, 10);

        // New AVS can
        vm.prank(newAvs);
        oracle.setScore(SUBJECT, 10);
        assertEq(oracle.getScore(SUBJECT), 10);
    }

    function test_setAvsRejectsZeroAddress() public {
        vm.expectRevert(ScoringOracle.ZeroAddress.selector);
        oracle.setAvs(address(0));
    }

    function test_transferOwnership() public {
        address newOwner = address(0xCAFE);
        oracle.transferOwnership(newOwner);

        // Old owner can no longer set AVS
        vm.expectRevert(ScoringOracle.NotOwner.selector);
        oracle.setAvs(address(0xBEEF));

        // New owner can
        vm.prank(newOwner);
        oracle.setAvs(address(0xBEEF));
    }
}
