// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GradientShieldServiceManager} from "../src/GradientShieldServiceManager.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";

import {ECDSAStakeRegistry} from "eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IECDSAStakeRegistryTypes} from "eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";
import {ISignatureUtilsMixinTypes} from
    "eigenlayer-contracts/src/contracts/interfaces/ISignatureUtilsMixin.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {DelegationMock} from "eigenlayer-middleware/test/mocks/DelegationMock.sol";
import {AVSDirectoryMock} from "eigenlayer-middleware/test/mocks/AVSDirectoryMock.sol";
import {AllocationManagerMock} from "eigenlayer-middleware/test/mocks/AllocationManagerMock.sol";
import {RewardsCoordinatorMock} from "eigenlayer-middleware/test/mocks/RewardsCoordinatorMock.sol";
import {ERC20Mock} from "eigenlayer-middleware/test/mocks/ERC20Mock.sol";

contract ServiceManagerTest is Test {
    GradientShieldServiceManager internal sm;
    ScoringOracle internal oracle;
    ECDSAStakeRegistry internal stakeRegistry;

    DelegationMock internal delegationMock;

    uint256 internal operatorPk = 0xA11CE;
    address internal operatorAddr;
    address internal deployer = address(0xDEAD);

    address internal constant BOT = address(0xB07);

    IStrategy internal mockStrategy;

    function setUp() public {
        operatorAddr = vm.addr(operatorPk);

        delegationMock = new DelegationMock();
        AVSDirectoryMock avsDirectoryMock = new AVSDirectoryMock();
        AllocationManagerMock allocationManagerMock = new AllocationManagerMock();
        RewardsCoordinatorMock rewardsCoordinatorMock = new RewardsCoordinatorMock();

        stakeRegistry = new ECDSAStakeRegistry(IDelegationManager(address(delegationMock)));
        oracle = new ScoringOracle(address(0));

        // Deploy implementation + proxy (ECDSAServiceManagerBase disables initializers in ctor)
        GradientShieldServiceManager impl = new GradientShieldServiceManager(
            address(avsDirectoryMock),
            address(stakeRegistry),
            address(rewardsCoordinatorMock),
            address(delegationMock),
            address(allocationManagerMock),
            oracle
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GradientShieldServiceManager.initialize, (deployer, deployer))
        );
        sm = GradientShieldServiceManager(address(proxy));

        mockStrategy = IStrategy(address(new ERC20Mock()));
        IECDSAStakeRegistryTypes.StrategyParams[] memory strategyParams =
            new IECDSAStakeRegistryTypes.StrategyParams[](1);
        strategyParams[0] = IECDSAStakeRegistryTypes.StrategyParams({
            strategy: mockStrategy,
            multiplier: 10_000
        });

        stakeRegistry.initialize(
            address(sm), 0, IECDSAStakeRegistryTypes.Quorum({strategies: strategyParams})
        );

        oracle.setAvs(address(sm));

        delegationMock.setIsOperator(operatorAddr, true);
        delegationMock.setOperatorShares(operatorAddr, mockStrategy, 1000 ether);
    }

    function _registerOperator() internal {
        ISignatureUtilsMixinTypes.SignatureWithSaltAndExpiry memory emptySig;
        emptySig.expiry = type(uint256).max;

        vm.prank(operatorAddr);
        stakeRegistry.registerOperatorWithSignature(emptySig, operatorAddr);
    }

    // -----------------------------------------------------------------
    // Operator registration (through EigenLayer's ECDSAStakeRegistry)
    // -----------------------------------------------------------------

    function test_registerOperator() public {
        _registerOperator();
        assertTrue(stakeRegistry.operatorRegistered(operatorAddr));
    }

    function test_cannotRegisterTwice() public {
        _registerOperator();

        ISignatureUtilsMixinTypes.SignatureWithSaltAndExpiry memory emptySig;
        emptySig.expiry = type(uint256).max;
        emptySig.salt = bytes32(uint256(1));

        vm.prank(operatorAddr);
        vm.expectRevert();
        stakeRegistry.registerOperatorWithSignature(emptySig, operatorAddr);
    }

    function test_deregisterOperator() public {
        _registerOperator();

        vm.prank(operatorAddr);
        stakeRegistry.deregisterOperator();

        assertFalse(stakeRegistry.operatorRegistered(operatorAddr));
    }

    // -----------------------------------------------------------------
    // Task creation
    // -----------------------------------------------------------------

    function test_createTask() public {
        vm.expectEmit(true, true, false, true);
        emit GradientShieldServiceManager.ScoreTaskCreated(0, BOT, 100, 200);

        uint32 taskId = sm.createScoreTask(BOT, 100, 200);
        assertEq(taskId, 0);
        assertEq(sm.taskCount(), 1);

        GradientShieldServiceManager.ScoreTask memory task = sm.getTask(0);
        assertEq(task.subject, BOT);
        assertEq(task.fromBlock, 100);
        assertEq(task.toBlock, 200);
        assertFalse(task.responded);
    }

    function test_createTaskRejectsInvalidRange() public {
        vm.expectRevert(GradientShieldServiceManager.InvalidBlockRange.selector);
        sm.createScoreTask(BOT, 200, 100);
    }

    // -----------------------------------------------------------------
    // Task response
    // -----------------------------------------------------------------

    function test_respondToTask() public {
        _registerOperator();
        uint32 taskId = sm.createScoreTask(BOT, 100, 200);

        uint16 score = 60;
        bytes memory sig = _signResponse(taskId, BOT, score);

        vm.prank(operatorAddr);
        sm.respondToTask(taskId, score, sig);

        assertTrue(sm.getTask(taskId).responded);
        assertEq(oracle.getScore(BOT), 60);
    }

    function test_cannotRespondTwice() public {
        _registerOperator();
        uint32 taskId = sm.createScoreTask(BOT, 100, 200);

        bytes memory sig = _signResponse(taskId, BOT, 60);
        vm.prank(operatorAddr);
        sm.respondToTask(taskId, 60, sig);

        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.TaskAlreadyResponded.selector);
        sm.respondToTask(taskId, 60, sig);
    }

    function test_unregisteredOperatorRejected() public {
        sm.createScoreTask(BOT, 100, 200);

        bytes memory sig = _signResponse(0, BOT, 60);
        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.OperatorNotRegistered.selector);
        sm.respondToTask(0, 60, sig);
    }

    function test_wrongSignatureRejected() public {
        _registerOperator();
        sm.createScoreTask(BOT, 100, 200);

        bytes memory wrongSig = _signResponse(0, BOT, 99);
        vm.prank(operatorAddr);
        vm.expectRevert(GradientShieldServiceManager.InvalidSignature.selector);
        sm.respondToTask(0, 60, wrongSig);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _signResponse(uint32 taskId, address subject, uint16 score) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(taskId, subject, score));
        bytes32 ethSignedHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
