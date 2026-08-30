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

const SCORING = {
  SANDWICH_DETECTED: 35,
  JIT_DETECTED: 25,
  IMPACT_CAP_HIT: 30,
  MULTI_POOL_ACTIVITY: 10,
  HIGH_FREQUENCY: 15,
  OPPOSITE_DIRECTION_RATIO: 20,
  MAX_SCORE: 100,
  MIN_FIRST_OFFENSE: 35,
};

async function computeScoreFromEvents(subject, fromBlock, toBlock) {
  if (!HOOK_ADDRESS) return null;

  const hook = new ethers.Contract(HOOK_ADDRESS, hookAbi, provider);
  let score = 0;
  const reasons = [];

  try {
    const sandwichLogs = await hook.queryFilter(hook.filters.SandwichDetected(null, subject), fromBlock, toBlock);
    if (sandwichLogs.length > 0) {
      const pts = SCORING.SANDWICH_DETECTED * sandwichLogs.length;
      score += pts;
      reasons.push(`${sandwichLogs.length} sandwich(es) → +${pts}`);
    }
  } catch {}

  try {
    const jitLogs = await hook.queryFilter(hook.filters.JITDetected(null, subject), fromBlock, toBlock);
    if (jitLogs.length > 0) {
      const pts = SCORING.JIT_DETECTED * jitLogs.length;
      score += pts;
      reasons.push(`${jitLogs.length} JIT(s) → +${pts}`);
    }
  } catch {}

  try {
    const capLogs = await hook.queryFilter(hook.filters.SenderImpactCapped(null, subject), fromBlock, toBlock);
    if (capLogs.length > 0) {
      const pts = SCORING.IMPACT_CAP_HIT * capLogs.length;
      score += pts;
      reasons.push(`${capLogs.length} impact cap hit(s) → +${pts}`);
    }
  } catch {}

  try {
    const telemetryLogs = await hook.queryFilter(hook.filters.SwapTelemetry(null, subject), fromBlock, toBlock);
    if (telemetryLogs.length >= 10) {
      score += SCORING.HIGH_FREQUENCY;
      reasons.push(`${telemetryLogs.length} swaps (high freq) → +${SCORING.HIGH_FREQUENCY}`);
    }

    const poolDirs = new Map();
    for (const log of telemetryLogs) {
      const poolId = log.topics[1];
      const decoded = hook.interface.decodeEventLog("SwapTelemetry", log.data, log.topics);
      if (!poolDirs.has(poolId)) poolDirs.set(poolId, { buys: 0, sells: 0 });
      const d = poolDirs.get(poolId);
      if (decoded[2]) d.buys++; else d.sells++;
    }

    let paired = 0;
    for (const [, d] of poolDirs) paired += Math.min(d.buys, d.sells) * 2;
    const ratio = telemetryLogs.length > 0 ? paired / telemetryLogs.length : 0;
    if (ratio > 0.4 && telemetryLogs.length >= 4) {
      score += SCORING.OPPOSITE_DIRECTION_RATIO;
      reasons.push(`${(ratio * 100).toFixed(0)}% round-trip → +${SCORING.OPPOSITE_DIRECTION_RATIO}`);
    }
  } catch {}

  if (score > 0 && score < SCORING.MIN_FIRST_OFFENSE) {
    score = SCORING.MIN_FIRST_OFFENSE;
    reasons.push(`first-offense floor → ${SCORING.MIN_FIRST_OFFENSE}`);
  }

  score = Math.min(score, SCORING.MAX_SCORE);
  return { score, reasons };
}

async function main() {
  const address = process.argv[2];
  const manualScore = process.argv[3] ? parseInt(process.argv[3]) : null;

  if (!address || !ethers.isAddress(address)) {
    console.log("Usage: node scoreAddress.js <address> [score]");
    console.log("  <address> - The address to score");
    console.log("  [score]   - Manual score 0-100 (skips auto-detection)");
    console.log("");
    console.log("Examples:");
    console.log("  node scoreAddress.js 0x1234...abcd       # auto-score from events");
    console.log("  node scoreAddress.js 0x1234...abcd 75    # manual score override");
    process.exit(1);
  }

  const currentScore = Number(await oracle.getScore(address));
  console.log(`Current score for ${address}: ${currentScore}`);
  console.log("");

  const currentBlock = await provider.getBlockNumber();
  const fromBlock = Math.max(0, currentBlock - 100);
  const toBlock = currentBlock;

  console.log("1. Creating score task...");
  const createTx = await sm.createScoreTask(address, fromBlock, toBlock);
  const createReceipt = await createTx.wait();

  let taskId;
  for (const log of createReceipt.logs) {
    try {
      const parsed = sm.interface.parseLog(log);
      if (parsed?.name === "ScoreTaskCreated") {
        taskId = Number(parsed.args.taskId);
        break;
      }
    } catch {}
  }
  console.log(`   Task ID: ${taskId}`);

  let score;
  if (manualScore !== null) {
    score = Math.min(100, Math.max(0, manualScore));
    console.log(`\n2. Using manual score: ${score}`);
  } else {
    console.log(`\n2. Analyzing on-chain activity (blocks ${fromBlock}-${toBlock})...`);
    const result = await computeScoreFromEvents(address, fromBlock, toBlock);
    if (result) {
      score = result.score;
      console.log("   Score breakdown:");
      for (const r of result.reasons) console.log(`     • ${r}`);
    } else {
      console.log("   HOOK_ADDRESS not set — using tx count fallback");
      let txCount = 0;
      for (let b = fromBlock; b <= toBlock; b++) {
        try {
          const block = await provider.getBlock(b, true);
          if (block?.transactions) {
            for (const txHash of block.transactions) {
              const tx = typeof txHash === "string" ? await provider.getTransaction(txHash) : txHash;
              if (tx?.from?.toLowerCase() === address.toLowerCase()) txCount++;
            }
          }
        } catch {}
      }
      if (txCount === 0) score = 0;
      else if (txCount <= 2) score = 15;
      else if (txCount <= 5) score = 40;
      else if (txCount <= 10) score = 65;
      else score = 90;
      console.log(`   Found ${txCount} txs → score ${score}`);
    }
  }

  const finalScore = Math.min(currentScore + score, 100);
  console.log(`\n   Cumulative: ${currentScore} + ${score} = ${finalScore}`);

  console.log("\n3. Signing and submitting...");
  const messageHash = ethers.solidityPackedKeccak256(
    ["uint32", "address", "uint16"],
    [taskId, address, finalScore]
  );
  const signature = await wallet.signMessage(ethers.getBytes(messageHash));

  const respondTx = await sm.respondToTask(taskId, finalScore, signature);
  const respondReceipt = await respondTx.wait();
  console.log(`   Tx: ${respondReceipt.hash}`);

  const newScore = Number(await oracle.getScore(address));
  console.log(`\nDone! Score for ${address}: ${currentScore} → ${newScore}`);

  if (newScore >= 80) {
    console.log("Hook action: SWAP REJECTED — bot is fully blocked");
  } else if (newScore >= 40) {
    const fee = 3000 + (15000 - 3000) * (newScore - 40) / 40;
    console.log(`Hook action: ESCALATED FEE — ${(fee / 10000).toFixed(2)}% (${Math.round(fee)} pips)`);
  } else {
    console.log("Hook action: BASE FEE — 0.30%");
  }
}

main().catch(console.error);
