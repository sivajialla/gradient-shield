import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const smAbi = JSON.parse(readFileSync(join(__dirname, "abi/ServiceManager.json"), "utf8"));
const oracleAbi = JSON.parse(readFileSync(join(__dirname, "abi/ScoringOracle.json"), "utf8"));
const hookAbi = JSON.parse(readFileSync(join(__dirname, "abi/GradientShieldHook.json"), "utf8"));

const { RPC_URL, OPERATOR_PRIVATE_KEY, SERVICE_MANAGER_ADDRESS, SCORING_ORACLE_ADDRESS, HOOK_ADDRESS } = process.env;

if (!RPC_URL || !OPERATOR_PRIVATE_KEY || !SERVICE_MANAGER_ADDRESS || !SCORING_ORACLE_ADDRESS) {
  console.error("Missing env vars. Copy .env.example to .env and fill in the values.");
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(OPERATOR_PRIVATE_KEY, provider);
const sm = new ethers.Contract(SERVICE_MANAGER_ADDRESS, smAbi, wallet);
const oracle = new ethers.Contract(SCORING_ORACLE_ADDRESS, oracleAbi, provider);

// =====================================================================
//  SCORING WEIGHTS
//  Each detection type adds points. Points compound with the current
//  oracle score via bumpScore, so repeat offenders escalate fast:
//
//  1st sandwich attempt → +35 (enters suspicious band at 35-40)
//  2nd sandwich attempt → +35 (cumulative ~70, deep suspicious)
//  3rd sandwich attempt → +35 (cumulative ~85+, REJECTED)
//
//  JIT is less harmful than sandwich, so lower weight.
//  Impact cap hits (blocked back-runs) prove intent — high weight.
// =====================================================================

const SCORING = {
  // Core MEV pattern detections (from hook events)
  SANDWICH_DETECTED: 35,       // SandwichDetected event — confirmed buy→victim→sell
  JIT_DETECTED: 25,            // JITDetected event — same-block add→swap→remove
  IMPACT_CAP_HIT: 30,          // SenderImpactCapped event — back-run was blocked
  BOT_REJECTED: 0,             // BotRejectedEvent — already scored high, no extra points

  // On-chain behavior signals (from swap analysis)
  MULTI_POOL_ACTIVITY: 10,     // Same address flagged across 3+ pools
  HIGH_FREQUENCY: 15,          // 10+ swaps in the block range
  OPPOSITE_DIRECTION_RATIO: 20, // >40% of swaps are buy/sell pairs (round-trip pattern)

  // Caps
  MAX_SCORE: 100,
  MIN_FIRST_OFFENSE: 35,      // First offense always enters suspicious zone
};

// =====================================================================
//  EVENT-BASED SCORING
//  Reads actual hook events in the block range to compute a score
//  based on what the address actually did, not just tx count.
// =====================================================================

async function computeScore(subject, fromBlock, toBlock) {
  console.log(`  Analyzing ${subject} from block ${fromBlock} to ${toBlock}...`);

  let score = 0;
  const reasons = [];

  // --- 1. Read hook events for this address ---
  const hookAddress = HOOK_ADDRESS;
  if (hookAddress) {
    const hook = new ethers.Contract(hookAddress, hookAbi, provider);

    const eventCounts = await scanHookEvents(hook, subject, fromBlock, toBlock);

    if (eventCounts.sandwich > 0) {
      const points = SCORING.SANDWICH_DETECTED * eventCounts.sandwich;
      score += points;
      reasons.push(`${eventCounts.sandwich} sandwich detection(s) → +${points}`);
    }

    if (eventCounts.jit > 0) {
      const points = SCORING.JIT_DETECTED * eventCounts.jit;
      score += points;
      reasons.push(`${eventCounts.jit} JIT detection(s) → +${points}`);
    }

    if (eventCounts.impactCap > 0) {
      const points = SCORING.IMPACT_CAP_HIT * eventCounts.impactCap;
      score += points;
      reasons.push(`${eventCounts.impactCap} impact cap hit(s) → +${points}`);
    }

    if (eventCounts.poolsActive >= 3) {
      score += SCORING.MULTI_POOL_ACTIVITY;
      reasons.push(`active in ${eventCounts.poolsActive} pools → +${SCORING.MULTI_POOL_ACTIVITY}`);
    }

    // --- 2. Analyze swap telemetry for behavioral signals ---
    const behavior = await analyzeSwapBehavior(hook, subject, fromBlock, toBlock);

    if (behavior.totalSwaps >= 10) {
      score += SCORING.HIGH_FREQUENCY;
      reasons.push(`${behavior.totalSwaps} swaps (high frequency) → +${SCORING.HIGH_FREQUENCY}`);
    }

    if (behavior.oppositeDirectionRatio > 0.4 && behavior.totalSwaps >= 4) {
      score += SCORING.OPPOSITE_DIRECTION_RATIO;
      reasons.push(`${(behavior.oppositeDirectionRatio * 100).toFixed(0)}% round-trip ratio → +${SCORING.OPPOSITE_DIRECTION_RATIO}`);
    }
  } else {
    // Fallback: no hook address configured, use tx count heuristic
    console.log("  WARNING: HOOK_ADDRESS not set, using tx count fallback");
    score = await fallbackTxCountScore(subject, fromBlock, toBlock);
    reasons.push(`fallback tx count scoring → ${score}`);
  }

  // --- 3. Apply minimum first-offense score ---
  // If we detected any MEV pattern at all, ensure the score is at least
  // MIN_FIRST_OFFENSE so the address enters the suspicious band.
  if (score > 0 && score < SCORING.MIN_FIRST_OFFENSE) {
    score = SCORING.MIN_FIRST_OFFENSE;
    reasons.push(`minimum first-offense floor applied → ${SCORING.MIN_FIRST_OFFENSE}`);
  }

  // Cap at MAX_SCORE
  score = Math.min(score, SCORING.MAX_SCORE);

  console.log(`  Score breakdown:`);
  for (const reason of reasons) {
    console.log(`    • ${reason}`);
  }
  console.log(`  Final score: ${score}`);

  return score;
}

// =====================================================================
//  HOOK EVENT SCANNER
//  Reads SandwichDetected, JITDetected, SenderImpactCapped events
//  for the target address in the given block range.
// =====================================================================

async function scanHookEvents(hook, subject, fromBlock, toBlock) {
  const counts = {
    sandwich: 0,
    jit: 0,
    impactCap: 0,
    poolsActive: 0,
  };

  const poolSet = new Set();

  try {
    // SandwichDetected(PoolId indexed, address indexed swapper, uint256)
    const sandwichFilter = hook.filters.SandwichDetected(null, subject);
    const sandwichLogs = await hook.queryFilter(sandwichFilter, fromBlock, toBlock);
    counts.sandwich = sandwichLogs.length;
    for (const log of sandwichLogs) {
      poolSet.add(log.topics[1]); // poolId
    }
  } catch (e) {
    console.log(`  Warning: could not fetch SandwichDetected events: ${e.message}`);
  }

  try {
    // JITDetected(PoolId indexed, address indexed provider, uint256)
    const jitFilter = hook.filters.JITDetected(null, subject);
    const jitLogs = await hook.queryFilter(jitFilter, fromBlock, toBlock);
    counts.jit = jitLogs.length;
    for (const log of jitLogs) {
      poolSet.add(log.topics[1]);
    }
  } catch (e) {
    console.log(`  Warning: could not fetch JITDetected events: ${e.message}`);
  }

  try {
    // SenderImpactCapped(PoolId indexed, address indexed sender, uint256, uint24)
    const capFilter = hook.filters.SenderImpactCapped(null, subject);
    const capLogs = await hook.queryFilter(capFilter, fromBlock, toBlock);
    counts.impactCap = capLogs.length;
    for (const log of capLogs) {
      poolSet.add(log.topics[1]);
    }
  } catch (e) {
    console.log(`  Warning: could not fetch SenderImpactCapped events: ${e.message}`);
  }

  counts.poolsActive = poolSet.size;
  return counts;
}

// =====================================================================
//  SWAP BEHAVIOR ANALYZER
//  Reads SwapTelemetry events to detect round-trip (buy/sell) patterns
//  and high-frequency activity.
// =====================================================================

async function analyzeSwapBehavior(hook, subject, fromBlock, toBlock) {
  const behavior = {
    totalSwaps: 0,
    buyCount: 0,
    sellCount: 0,
    oppositeDirectionRatio: 0,
  };

  try {
    // SwapTelemetry(PoolId indexed, address indexed swapper, bool zeroForOne, ...)
    const telemetryFilter = hook.filters.SwapTelemetry(null, subject);
    const telemetryLogs = await hook.queryFilter(telemetryFilter, fromBlock, toBlock);

    behavior.totalSwaps = telemetryLogs.length;

    // Per-pool direction tracking
    const poolDirections = new Map(); // poolId → { buys: n, sells: n }

    for (const log of telemetryLogs) {
      const poolId = log.topics[1];
      const decoded = hook.interface.decodeEventLog("SwapTelemetry", log.data, log.topics);
      const zeroForOne = decoded[2]; // bool

      if (!poolDirections.has(poolId)) {
        poolDirections.set(poolId, { buys: 0, sells: 0 });
      }
      const dirs = poolDirections.get(poolId);
      if (zeroForOne) dirs.buys++;
      else dirs.sells++;
    }

    // Calculate round-trip ratio: how many swaps are part of a buy/sell pair
    let pairedSwaps = 0;
    for (const [, dirs] of poolDirections) {
      pairedSwaps += Math.min(dirs.buys, dirs.sells) * 2;
    }

    if (behavior.totalSwaps > 0) {
      behavior.oppositeDirectionRatio = pairedSwaps / behavior.totalSwaps;
    }
  } catch (e) {
    console.log(`  Warning: could not analyze swap behavior: ${e.message}`);
  }

  return behavior;
}

// =====================================================================
//  FALLBACK: TX COUNT (when HOOK_ADDRESS not configured)
// =====================================================================

async function fallbackTxCountScore(subject, fromBlock, toBlock) {
  let txCount = 0;
  const start = Math.max(fromBlock, toBlock - 500);

  for (let block = start; block <= toBlock; block++) {
    try {
      const blockData = await provider.getBlock(block, true);
      if (blockData?.transactions) {
        for (const txHash of blockData.transactions) {
          const tx = typeof txHash === "string" ? await provider.getTransaction(txHash) : txHash;
          if (tx?.from?.toLowerCase() === subject.toLowerCase()) txCount++;
        }
      }
    } catch {}
  }

  if (txCount === 0) return 0;
  if (txCount <= 2) return 15;
  if (txCount <= 5) return 40;
  if (txCount <= 10) return 65;
  return 90;
}

// =====================================================================
//  TASK HANDLER
// =====================================================================

async function signAndRespond(taskId, subject, score) {
  const messageHash = ethers.solidityPackedKeccak256(
    ["uint32", "address", "uint16"],
    [taskId, subject, score]
  );
  const signature = await wallet.signMessage(ethers.getBytes(messageHash));

  console.log(`  Submitting score ${score} for task ${taskId}...`);
  const tx = await sm.respondToTask(taskId, score, signature);
  const receipt = await tx.wait();
  console.log(`  Submitted in tx: ${receipt.hash}`);
}

async function handleTask(taskId, subject, fromBlock, toBlock) {
  console.log(`\n${"=".repeat(60)}`);
  console.log(`Task ${taskId}: scoring ${subject}`);
  console.log(`${"=".repeat(60)}`);

  const currentScore = Number(await oracle.getScore(subject));
  console.log(`  Current oracle score: ${currentScore}`);

  const newScore = await computeScore(subject, fromBlock, toBlock);

  // The final on-chain score will be: currentDecayedScore + newScore
  // (via bumpScore), so the operator submits just the delta.
  // But since respondToTask calls setScore (absolute), we add to current.
  const finalScore = Math.min(currentScore + newScore, SCORING.MAX_SCORE);
  console.log(`  Cumulative score: ${currentScore} + ${newScore} = ${finalScore}`);

  // Show what the hook will do with this score
  if (finalScore >= 80) {
    console.log(`  Hook action: SWAP REJECTED — bot is blocked from trading`);
  } else if (finalScore >= 40) {
    const fee = 3000 + (15000 - 3000) * (finalScore - 40) / 40;
    console.log(`  Hook action: ESCALATED FEE — ${(fee / 10000).toFixed(2)}% (${Math.round(fee)} pips)`);
  } else {
    console.log(`  Hook action: BASE FEE — 0.30%`);
  }

  await signAndRespond(taskId, subject, finalScore);

  const updatedScore = Number(await oracle.getScore(subject));
  console.log(`  Oracle score after update: ${updatedScore}`);
}

// =====================================================================
//  MAIN — LISTEN FOR TASKS
// =====================================================================

async function main() {
  const network = await provider.getNetwork();
  console.log(`${"=".repeat(60)}`);
  console.log(`GradientShield Operator (Event-Based Scoring)`);
  console.log(`${"=".repeat(60)}`);
  console.log(`Chain:          ${network.name} (${network.chainId})`);
  console.log(`Operator:       ${wallet.address}`);
  console.log(`ServiceManager: ${SERVICE_MANAGER_ADDRESS}`);
  console.log(`ScoringOracle:  ${SCORING_ORACLE_ADDRESS}`);
  console.log(`Hook:           ${HOOK_ADDRESS || "NOT SET (using fallback)"}`);
  console.log(``);
  console.log(`Scoring weights:`);
  console.log(`  Sandwich detected:    +${SCORING.SANDWICH_DETECTED} per occurrence`);
  console.log(`  JIT detected:         +${SCORING.JIT_DETECTED} per occurrence`);
  console.log(`  Impact cap hit:       +${SCORING.IMPACT_CAP_HIT} per occurrence`);
  console.log(`  Multi-pool (3+):      +${SCORING.MULTI_POOL_ACTIVITY}`);
  console.log(`  High frequency (10+): +${SCORING.HIGH_FREQUENCY}`);
  console.log(`  Round-trip ratio >40%: +${SCORING.OPPOSITE_DIRECTION_RATIO}`);
  console.log(`  First offense floor:   ${SCORING.MIN_FIRST_OFFENSE}`);
  console.log(``);
  console.log(`Escalation path:`);
  console.log(`  1st sandwich → +35 → suspicious (escalated fee)`);
  console.log(`  2nd sandwich → +35 → deep suspicious (~70, 1.25% fee)`);
  console.log(`  3rd sandwich → +35 → REJECTED (score 85+, blocked)`);
  console.log(``);
  console.log(`Listening for ScoreTaskCreated events...`);
  console.log(``);

  sm.on("ScoreTaskCreated", async (taskId, subject, fromBlock, toBlock) => {
    try {
      await handleTask(Number(taskId), subject, Number(fromBlock), Number(toBlock));
    } catch (err) {
      console.error(`  Error handling task ${taskId}:`, err.message);
    }
  });

  const taskCount = await sm.taskCount();
  console.log(`Checking ${taskCount} existing tasks for unresponded ones...`);

  for (let i = 0; i < taskCount; i++) {
    const task = await sm.getTask(i);
    if (!task.responded) {
      try {
        await handleTask(i, task.subject, Number(task.fromBlock), Number(task.toBlock));
      } catch (err) {
        console.error(`  Error handling task ${i}:`, err.message);
      }
    }
  }

  console.log("\nOperator running. Press Ctrl+C to stop.");
}

main().catch(console.error);
