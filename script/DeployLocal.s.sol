// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {GradientShieldHook} from "../src/GradientShieldHook.sol";
import {IScoreTaskCreator} from "../src/IScoreTaskCreator.sol";
import {ScoringOracle} from "../src/ScoringOracle.sol";
import {BLSQuorumTaskManager} from "../src/BLSQuorumTaskManager.sol";
import {BN254Lib} from "../src/libraries/BN254Lib.sol";

/// @title DeployLocal
/// @notice One-shot local demo deployment: PoolManager, tokens, a dynamic-fee
///         pool with GradientShieldHook, and a live BLS operator quorum.
///
/// Everything needed to run the AVS loop end-to-end on a bare anvil node —
/// no EigenLayer infrastructure required.
///
/// Usage:
///   anvil                                  # terminal 1
///   make deploy-local                      # terminal 2
///   make avs                               # terminal 3 (operator quorum)
///   make attack                            # terminal 4 (run a sandwich)
///
/// Operator BLS keys are read from operator/keys.json so the on-chain registry
/// and the off-chain signers share one source of truth. Regenerate with
/// `node operator/blsKeygen.js`.
contract DeployLocal is Script {
    using stdJson for string;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // The deployer is both the task generator and the aggregator locally.
        vm.startBroadcast(pk);

        PoolManager poolManager = new PoolManager(deployer);
        ScoringOracle oracle = new ScoringOracle(address(0));
        BLSQuorumTaskManager tm = new BLSQuorumTaskManager(oracle, deployer, deployer);
        oracle.setAvs(address(tm));

        GradientShieldHook hook = _deployHook(poolManager, oracle, tm);
        tm.setHookAddress(address(hook));

        _registerOperators(tm);
        (PoolKey memory key, address swapRouter) = _createPool(poolManager, hook, deployer);

        vm.stopBroadcast();

        _writeEnv(oracle, tm, hook, key, swapRouter);
        _report(poolManager, oracle, tm, hook, key, swapRouter, deployer);
    }

    // -----------------------------------------------------------------

    function _deployHook(PoolManager poolManager, ScoringOracle oracle, BLSQuorumTaskManager tm)
        internal
        returns (GradientShieldHook hook)
    {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory args =
            abi.encode(IPoolManager(address(poolManager)), oracle, IScoreTaskCreator(address(tm)), address(0));

        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GradientShieldHook).creationCode, args);

        hook = new GradientShieldHook{salt: salt}(
            IPoolManager(address(poolManager)), oracle, IScoreTaskCreator(address(tm)), address(0)
        );
        require(address(hook) == expected, "DeployLocal: hook address mismatch");
    }

    /// @dev Reads the demo quorum's BLS public keys from operator/keys.json.
    function _registerOperators(BLSQuorumTaskManager tm) internal {
        string memory json = vm.readFile("operator/keys.json");

        for (uint256 i = 0; i < 3; i++) {
            string memory base = string.concat(".operators[", vm.toString(i), "]");

            address operator = vm.addr(uint256(json.readBytes32(string.concat(base, ".privateKey"))));

            BN254Lib.G1Point memory pkG1 = BN254Lib.G1Point({
                X: uint256(json.readBytes32(string.concat(base, ".pkG1.X"))),
                Y: uint256(json.readBytes32(string.concat(base, ".pkG1.Y")))
            });

            BN254Lib.G2Point memory pkG2 = BN254Lib.G2Point({
                X: [
                    uint256(json.readBytes32(string.concat(base, ".pkG2.X[0]"))),
                    uint256(json.readBytes32(string.concat(base, ".pkG2.X[1]")))
                ],
                Y: [
                    uint256(json.readBytes32(string.concat(base, ".pkG2.Y[0]"))),
                    uint256(json.readBytes32(string.concat(base, ".pkG2.Y[1]")))
                ]
            });

            tm.registerOperator(operator, pkG1, pkG2);
        }
    }

    /// @param deployer Receives the demo token supply. Inside a broadcast the
    ///        script contract is `msg.sender`, not the broadcasting EOA, so the
    ///        recipient has to be passed in explicitly.
    function _createPool(PoolManager poolManager, GradientShieldHook hook, address deployer)
        internal
        returns (PoolKey memory key, address swapRouter)
    {
        MockERC20 tokenA = new MockERC20("Demo WETH", "WETH", 18);
        MockERC20 tokenB = new MockERC20("Demo USDC", "USDC", 18);

        (MockERC20 token0, MockERC20 token1) =
            address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(poolManager)));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        token0.mint(deployer, 1_000_000 ether);
        token1.mint(deployer, 1_000_000 ether);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 1:1 starting price
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100_000 ether,
                salt: bytes32(0)
            }),
            ""
        );

        swapRouter = address(router);
    }

    /// @dev Writes operator/.env itself rather than asking the operator to copy
    ///      eight addresses by hand. `make avs` and `make attack` then work with
    ///      no further setup.
    function _writeEnv(
        ScoringOracle oracle,
        BLSQuorumTaskManager tm,
        GradientShieldHook hook,
        PoolKey memory key,
        address swapRouter
    ) internal {
        string memory env = string.concat(
            "# Generated by script/DeployLocal.s.sol - safe to overwrite.\n",
            "RPC_URL=http://127.0.0.1:8545\n",
            "# anvil account 0: deployer, task generator and aggregator.\n",
            "AGGREGATOR_PRIVATE_KEY=",
            "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80\n",
            "TASK_MANAGER_ADDRESS=",
            vm.toString(address(tm)),
            "\n",
            "SCORING_ORACLE_ADDRESS=",
            vm.toString(address(oracle)),
            "\n",
            "HOOK_ADDRESS=",
            vm.toString(address(hook)),
            "\n",
            "SWAP_ROUTER=",
            vm.toString(swapRouter),
            "\n",
            "TOKEN0=",
            vm.toString(Currency.unwrap(key.currency0)),
            "\n",
            "TOKEN1=",
            vm.toString(Currency.unwrap(key.currency1)),
            "\n"
        );
        vm.writeFile("operator/.env", env);
    }

    function _report(
        PoolManager poolManager,
        ScoringOracle oracle,
        BLSQuorumTaskManager tm,
        GradientShieldHook hook,
        PoolKey memory key,
        address swapRouter,
        address deployer
    ) internal pure {
        console2.log("");
        console2.log("=== GRADIENTSHIELD LOCAL DEPLOYMENT ===");
        console2.log("POOL_MANAGER        =", address(poolManager));
        console2.log("SCORING_ORACLE      =", address(oracle));
        console2.log("TASK_MANAGER        =", address(tm));
        console2.log("HOOK_ADDRESS        =", address(hook));
        console2.log("SWAP_ROUTER         =", swapRouter);
        console2.log("TOKEN0              =", Currency.unwrap(key.currency0));
        console2.log("TOKEN1              =", Currency.unwrap(key.currency1));
        console2.log("AGGREGATOR          =", deployer);
        console2.log("");
        console2.log("Wrote operator/.env. Next: make avs (new terminal), then make attack");
    }
}
