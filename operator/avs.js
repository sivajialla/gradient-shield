// GradientShield AVS — operator quorum + aggregator.
//
// Watches BLSQuorumTaskManager for ScoreTaskCreated, scores the subject from
// the hook's own on-chain events, has every operator sign the verdict with its
// BLS key, aggregates the signatures, and submits the quorum response.
//
// In production each operator is a separate process holding one key, and the
// aggregator is a distinct service. For the demo all of them run here so the
// whole loop can be shown in one terminal. The cryptography is identical
// either way — the contract cannot tell the difference.
//
//   node avs.js

import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

import { sign, aggregateG1, aggregateG2, scoreMessageHash } from "./bls.js";
import { computeScore } from "./scoring.js";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const abi = (n) => JSON.parse(readFileSync(join(__dirname, `abi/${n}.json`), "utf8"));

const { RPC_URL, AGGREGATOR_PRIVATE_KEY, TASK_MANAGER_ADDRESS, SCORING_ORACLE_ADDRESS, HOOK_ADDRESS } =
  process.env;

if (!RPC_URL || !AGGREGATOR_PRIVATE_KEY || !TASK_MANAGER_ADDRESS || !SCORING_ORACLE_ADDRESS) {
  console.error(
    "Missing env vars. Copy .env.example to .env and fill in:\n" +
      "  RPC_URL, AGGREGATOR_PRIVATE_KEY, TASK_MANAGER_ADDRESS, SCORING_ORACLE_ADDRESS, HOOK_ADDRESS"
  );
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const aggregatorWallet = new ethers.Wallet(AGGREGATOR_PRIVATE_KEY, provider);

const tm = new ethers.Contract(TASK_MANAGER_ADDRESS, abi("BLSQuorumTaskManager"), aggregatorWallet);
const oracle = new ethers.Contract(SCORING_ORACLE_ADDRESS, abi("ScoringOracle"), provider);
const hook = HOOK_ADDRESS ? new ethers.Contract(HOOK_ADDRESS, abi("GradientShieldHook"), provider) : null;

const keys = JSON.parse(readFileSync(join(__dirname, "keys.json"), "utf8"));

// ---------------------------------------------------------------------------
// Quorum response
// ---------------------------------------------------------------------------

/**
 * Every registered operator signs the same (taskIndex, subject, score) digest.
 * Signatures are summed in G1 and public keys in G2; the contract re-derives
 * apkG1 from its own registry, so we never get to choose it.
 */
function signQuorum(taskIndex, subject, score, signerIdxs) {
  const msgHash = scoreMessageHash(ethers, taskIndex, subject, score);

  const partials = signerIdxs.map((i) => {
    const sk = BigInt(keys.operators[i].privateKey);
    return sign(sk, msgHash);
  });

  const pkG2s = signerIdxs.map((i) => {
    const p = keys.operators[i].pkG2;
    return {
      X: [BigInt(p.X[0]), BigInt(p.X[1])],
      Y: [BigInt(p.Y[0]), BigInt(p.Y[1])],
    };
  });

  return { sigma: aggregateG1(partials), apkG2: aggregateG2(pkG2s) };
}

async function respondToTask(taskIndex, subject, score) {
  const total = Number(await tm.operatorCount());
  const signerIdxs = [...Array(total).keys()].filter((i) => i < keys.operators.length);

  const { sigma, apkG2 } = signQuorum(taskIndex, subject, score, signerIdxs);

  console.log(`  ${signerIdxs.length}/${total} operators signed score=${score}`);
  console.log(`  Aggregate sigma.X = 0x${sigma.X.toString(16).slice(0, 16)}…`);

  const tx = await tm.respondToScoreTask(
    taskIndex,
    score,
    signerIdxs,
    { X: [apkG2.X[0], apkG2.X[1]], Y: [apkG2.Y[0], apkG2.Y[1]] },
    { X: sigma.X, Y: sigma.Y }
  );
  const receipt = await tx.wait();
  console.log(`  BLS pairing verified on-chain — tx ${receipt.hash}`);
}

// ---------------------------------------------------------------------------
// Task handling
// ---------------------------------------------------------------------------

async function handleTask(taskIndex, subject, fromBlock, toBlock) {
  console.log("");
  console.log("=".repeat(64));
  console.log(`Task ${taskIndex} — scoring ${subject}`);
  console.log("=".repeat(64));

  const current = Number(await oracle.getScore(subject));
  console.log(`  Current oracle score: ${current}`);

  const delta = await computeScore({ hook, provider, subject, fromBlock, toBlock });
  const score = Math.min(current + delta, 100);
  console.log(`  Cumulative verdict: ${current} + ${delta} = ${score}`);

  if (score >= 80) {
    console.log("  Hook action: SWAP REJECTED — address is blocked from the pool");
  } else if (score >= 40) {
    const fee = 3000 + ((15000 - 3000) * (score - 40)) / 40;
    console.log(`  Hook action: ESCALATED FEE — ${(fee / 10000).toFixed(2)}%`);
  } else {
    console.log("  Hook action: BASE FEE — 0.30%");
  }

  await respondToTask(taskIndex, subject, score);
  console.log(`  Oracle score is now: ${Number(await oracle.getScore(subject))}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const net = await provider.getNetwork();
  const total = Number(await tm.operatorCount());

  console.log("=".repeat(64));
  console.log("GradientShield AVS — BLS quorum");
  console.log("=".repeat(64));
  console.log(`Chain:        ${net.name} (${net.chainId})`);
  console.log(`TaskManager:  ${TASK_MANAGER_ADDRESS}`);
  console.log(`Oracle:       ${SCORING_ORACLE_ADDRESS}`);
  console.log(`Hook:         ${HOOK_ADDRESS || "NOT SET — scoring will be degraded"}`);
  console.log(`Aggregator:   ${aggregatorWallet.address}`);
  console.log(`Operators:    ${total} registered on-chain, ${keys.operators.length} keys loaded`);
  console.log("");

  if (total === 0) {
    console.error("No operators registered on the TaskManager. Run the deploy script first.");
    process.exit(1);
  }

  // Answer anything already outstanding.
  const latest = Number(await tm.latestTaskNum());
  for (let i = 0; i < latest; i++) {
    const t = await tm.getTask(i);
    if (!t.responded) {
      await handleTask(i, t.subject, Number(t.fromBlock), Number(t.toBlock)).catch((e) =>
        console.error(`  Task ${i} failed: ${e.message}`)
      );
    }
  }

  console.log(`Watching for ScoreTaskCreated… (${latest} task(s) seen so far)`);

  tm.on("ScoreTaskCreated", async (taskIndex, subject, fromBlock, toBlock) => {
    try {
      await handleTask(Number(taskIndex), subject, Number(fromBlock), Number(toBlock));
    } catch (e) {
      console.error(`  Task ${taskIndex} failed: ${e.message}`);
    }
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
