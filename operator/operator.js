import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const smAbi = JSON.parse(readFileSync(join(__dirname, "abi/ServiceManager.json"), "utf8"));
const oracleAbi = JSON.parse(readFileSync(join(__dirname, "abi/ScoringOracle.json"), "utf8"));

const { RPC_URL, OPERATOR_PRIVATE_KEY, SERVICE_MANAGER_ADDRESS, SCORING_ORACLE_ADDRESS } = process.env;

if (!RPC_URL || !OPERATOR_PRIVATE_KEY || !SERVICE_MANAGER_ADDRESS || !SCORING_ORACLE_ADDRESS) {
  console.error("Missing env vars. Copy .env.example to .env and fill in the values.");
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(OPERATOR_PRIVATE_KEY, provider);
const sm = new ethers.Contract(SERVICE_MANAGER_ADDRESS, smAbi, wallet);
const oracle = new ethers.Contract(SCORING_ORACLE_ADDRESS, oracleAbi, provider);

// Simple MEV heuristic: count transactions from an address in a block range.
// High tx count in a short window = likely bot activity.
async function computeScore(subject, fromBlock, toBlock) {
  console.log(`  Analyzing ${subject} from block ${fromBlock} to ${toBlock}...`);

  let txCount = 0;
  const batchSize = 100;
  const start = Math.max(fromBlock, toBlock - 500); // limit scan range

  for (let block = start; block <= toBlock; block += batchSize) {
    const end = Math.min(block + batchSize - 1, toBlock);
    try {
      const blockData = await provider.getBlock(end, true);
      if (blockData && blockData.transactions) {
        for (const txHash of blockData.transactions) {
          const tx = typeof txHash === "string" ? await provider.getTransaction(txHash) : txHash;
          if (tx && tx.from && tx.from.toLowerCase() === subject.toLowerCase()) {
            txCount++;
          }
        }
      }
    } catch {
      // Skip blocks we can't fetch
    }
  }

  // Scoring heuristic:
  //   0 txs in window    -> score 0  (clean)
  //   1-2 txs            -> score 15 (normal)
  //   3-5 txs            -> score 40 (suspicious)
  //   6-10 txs           -> score 65 (likely bot)
  //   11+ txs            -> score 90 (confirmed bot)
  let score;
  if (txCount === 0) score = 0;
  else if (txCount <= 2) score = 15;
  else if (txCount <= 5) score = 40;
  else if (txCount <= 10) score = 65;
  else score = 90;

  console.log(`  Found ${txCount} transactions -> score ${score}`);
  return score;
}

async function signAndRespond(taskId, subject, score) {
  // Build the same message hash the contract expects
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
  console.log(`\nTask ${taskId}: scoring ${subject}`);

  // Check current score
  const currentScore = await oracle.getScore(subject);
  console.log(`  Current oracle score: ${currentScore}`);

  // Compute new score from on-chain analysis
  const score = await computeScore(subject, fromBlock, toBlock);

  // Sign and submit
  await signAndRespond(taskId, subject, score);

  // Verify
  const newScore = await oracle.getScore(subject);
  console.log(`  Oracle score after update: ${newScore}`);
}

async function main() {
  const network = await provider.getNetwork();
  console.log(`GradientShield Operator`);
  console.log(`Chain: ${network.name} (${network.chainId})`);
  console.log(`Operator: ${wallet.address}`);
  console.log(`ServiceManager: ${SERVICE_MANAGER_ADDRESS}`);
  console.log(`ScoringOracle: ${SCORING_ORACLE_ADDRESS}`);
  console.log(`\nListening for ScoreTaskCreated events...\n`);

  // Listen for new tasks
  sm.on("ScoreTaskCreated", async (taskId, subject, fromBlock, toBlock, event) => {
    try {
      await handleTask(
        Number(taskId),
        subject,
        Number(fromBlock),
        Number(toBlock)
      );
    } catch (err) {
      console.error(`  Error handling task ${taskId}:`, err.message);
    }
  });

  // Also process any unresponded tasks that already exist
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
