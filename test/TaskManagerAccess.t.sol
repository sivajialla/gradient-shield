// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSSignatureChecker} from "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "eigenlayer-middleware/src/libraries/BN254.sol";

import {GradientShieldTaskManager} from "../src/GradientShieldTaskManager.sol";
import {IGradientShieldTaskManager} from "../src/IGradientShieldTaskManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

/// @title TaskManager Access Control Tests
/// @notice Verifies onlyOwner, onlyAggregator, onlyTaskCreator guards,
///         and that raiseAndResolveChallenge is intentionally permissionless.
contract TaskManagerAccessTest is Test {
    using BN254 for BN254.G1Point;

    GradientShieldTaskManager internal tm;
    ScoringOracle internal oracle;

    address internal owner      = address(this);
    address internal aggregator = address(0xACC1);
    address internal generator  = address(0x6E71);
    address internal hookAddr   = address(0x400C);
    address internal attacker   = address(0xBAD);

    function setUp() public {
        MockPauserReg mockPR = new MockPauserReg();
        MockRegCoord mockRC = new MockRegCoord();

        oracle = new ScoringOracle(address(0));

        GradientShieldTaskManager tmImpl = new GradientShieldTaskManager(
            ISlashingRegistryCoordinator(address(mockRC)),
            IPauserRegistry(address(mockPR)),
            100
        );
        ERC1967Proxy tmProxy = new ERC1967Proxy(
            address(tmImpl),
            abi.encodeCall(GradientShieldTaskManager.initialize, (owner, aggregator, generator, oracle))
        );
        tm = GradientShieldTaskManager(address(tmProxy));
        oracle.setAvs(address(tm));
        tm.setHookAddress(hookAddr);
    }

    // =====================================================================
    //  setHookAddress — onlyOwner
    // =====================================================================

    function test_setHookAddress_ownerSucceeds() public {
        tm.setHookAddress(address(0x1111));
        assertEq(tm.hookAddress(), address(0x1111));
    }

    function test_setHookAddress_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        tm.setHookAddress(address(0x1111));
    }

    function test_setHookAddress_aggregatorReverts() public {
        vm.prank(aggregator);
        vm.expectRevert();
        tm.setHookAddress(address(0x1111));
    }

    function test_setHookAddress_generatorReverts() public {
        vm.prank(generator);
        vm.expectRevert();
        tm.setHookAddress(address(0x1111));
    }

    // =====================================================================
    //  createScoreTask — onlyTaskCreator (generator OR hook)
    // =====================================================================

    function test_createTask_generatorSucceeds() public {
        vm.prank(generator);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");
        assertEq(tm.latestTaskNum(), 1);
    }

    function test_createTask_hookSucceeds() public {
        vm.prank(hookAddr);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");
        assertEq(tm.latestTaskNum(), 1);
    }

    function test_createTask_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(IGradientShieldTaskManager.NotGenerator.selector);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");
    }

    function test_createTask_ownerReverts() public {
        vm.expectRevert(IGradientShieldTaskManager.NotGenerator.selector);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");
    }

    function test_createTask_aggregatorReverts() public {
        vm.prank(aggregator);
        vm.expectRevert(IGradientShieldTaskManager.NotGenerator.selector);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");
    }

    // =====================================================================
    //  respondToScoreTask — onlyAggregator
    // =====================================================================

    function test_respond_attackerReverts() public {
        _createTask(address(0xBEEF));

        (IGradientShieldTaskManager.ScoreTask memory task,
         IGradientShieldTaskManager.ScoreTaskResponse memory resp) = _makeTaskAndResponse(address(0xBEEF), 0);

        IBLSSignatureChecker.NonSignerStakesAndSignature memory emptySig;

        vm.prank(attacker);
        vm.expectRevert(IGradientShieldTaskManager.NotAggregator.selector);
        tm.respondToScoreTask(task, resp, emptySig);
    }

    function test_respond_generatorReverts() public {
        _createTask(address(0xBEEF));

        (IGradientShieldTaskManager.ScoreTask memory task,
         IGradientShieldTaskManager.ScoreTaskResponse memory resp) = _makeTaskAndResponse(address(0xBEEF), 0);

        IBLSSignatureChecker.NonSignerStakesAndSignature memory emptySig;

        vm.prank(generator);
        vm.expectRevert(IGradientShieldTaskManager.NotAggregator.selector);
        tm.respondToScoreTask(task, resp, emptySig);
    }

    function test_respond_ownerReverts() public {
        _createTask(address(0xBEEF));

        (IGradientShieldTaskManager.ScoreTask memory task,
         IGradientShieldTaskManager.ScoreTaskResponse memory resp) = _makeTaskAndResponse(address(0xBEEF), 0);

        IBLSSignatureChecker.NonSignerStakesAndSignature memory emptySig;

        vm.expectRevert(IGradientShieldTaskManager.NotAggregator.selector);
        tm.respondToScoreTask(task, resp, emptySig);
    }

    // =====================================================================
    //  raiseAndResolveChallenge — permissionless (by design)
    // =====================================================================

    function test_challenge_isPermissionless() public {
        // Anyone can call challenge — no access control revert
        // It should fail with NotResponded, not an access gate
        IGradientShieldTaskManager.ScoreTask memory task = IGradientShieldTaskManager.ScoreTask({
            subject: address(0xBEEF),
            fromBlock: 0,
            toBlock: 10,
            taskCreatedBlock: 0,
            quorumNumbers: hex"00",
            quorumThresholdPercentage: 67
        });
        IGradientShieldTaskManager.ScoreTaskResponse memory resp = IGradientShieldTaskManager.ScoreTaskResponse({
            referenceTaskIndex: 0,
            score: 50
        });
        IGradientShieldTaskManager.TaskResponseMetadata memory meta = IGradientShieldTaskManager.TaskResponseMetadata({
            taskResponsedBlock: 0,
            hashOfNonSigners: bytes32(0)
        });
        BN254.G1Point[] memory pubkeys = new BN254.G1Point[](0);

        vm.prank(attacker);
        vm.expectRevert(IGradientShieldTaskManager.NotResponded.selector);
        tm.raiseAndResolveChallenge(task, resp, meta, pubkeys);
    }

    // =====================================================================
    //  initialize — cannot re-initialize
    // =====================================================================

    function test_cannotReinitialize() public {
        vm.expectRevert();
        tm.initialize(attacker, attacker, attacker, oracle);
    }

    // =====================================================================
    //  Role separation
    // =====================================================================

    function test_roleSeparation() public view {
        assertTrue(owner != aggregator);
        assertTrue(owner != generator);
        assertTrue(aggregator != generator);
        assertEq(tm.aggregator(), aggregator);
        assertEq(tm.generator(), generator);
        assertEq(tm.hookAddress(), hookAddr);
    }

    function test_hookAddressUpdateDoesNotAffectGenerator() public {
        address newHook = address(0x5555);
        tm.setHookAddress(newHook);

        // Generator can still create tasks
        vm.prank(generator);
        tm.createScoreTask(address(0xBEEF), 0, 10, 67, hex"00");

        // New hook can also create tasks
        vm.prank(newHook);
        tm.createScoreTask(address(0xDEAD), 0, 10, 67, hex"00");

        // Old hook can no longer create tasks
        vm.prank(hookAddr);
        vm.expectRevert(IGradientShieldTaskManager.NotGenerator.selector);
        tm.createScoreTask(address(0xCAFE), 0, 10, 67, hex"00");
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _createTask(address subject) internal {
        vm.prank(generator);
        tm.createScoreTask(subject, 0, 10, 67, hex"00");
    }

    function _makeTaskAndResponse(address subject, uint32 taskIndex)
        internal
        view
        returns (
            IGradientShieldTaskManager.ScoreTask memory task,
            IGradientShieldTaskManager.ScoreTaskResponse memory resp
        )
    {
        task = IGradientShieldTaskManager.ScoreTask({
            subject: subject,
            fromBlock: 0,
            toBlock: 10,
            taskCreatedBlock: uint32(block.number),
            quorumNumbers: hex"00",
            quorumThresholdPercentage: 67
        });
        resp = IGradientShieldTaskManager.ScoreTaskResponse({
            referenceTaskIndex: taskIndex,
            score: 50
        });
    }
}

// Minimal mocks
contract MockPauserReg {
    function isPauser(address) external pure returns (bool) { return true; }
    function unpauser() external pure returns (address) { return address(1); }
}

contract MockRegCoord {
    MockSR public immutable sr;
    MockAPK public immutable apk;
    constructor() {
        MockDel del = new MockDel();
        sr = new MockSR(address(del));
        apk = new MockAPK();
    }
    function stakeRegistry() external view returns (address) { return address(sr); }
    function blsApkRegistry() external view returns (address) { return address(apk); }
    function quorumCount() external pure returns (uint8) { return 0; }
}

contract MockDel {}
contract MockSR {
    address public immutable d;
    constructor(address _d) { d = _d; }
    function delegation() external view returns (address) { return d; }
}
contract MockAPK {}
