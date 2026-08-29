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

// One-shot: create task + score + submit, all in one command.
async function main() {
  const address = process.argv[2];
  const manualScore = process.argv[3] ? parseInt(process.argv[3]) : null;

  if (!address || !ethers.isAddress(address)) {
    console.log("Usage: node scoreAddress.js <address> [score]");
    console.log("  <address> - The address to score");
    console.log("  [score]   - Manual score 0-100 (skips auto-detection)");
    console.log("");
    console.log("Examples:");
    console.log("  node scoreAddress.js 0x1234...abcd       # auto-score");
    console.log("  node scoreAddress.js 0x1234...abcd 75    # manual score");
    process.exit(1);
  }

  // Show current score
  const currentScore = await oracle.getScore(address);
  console.log(`Current score for ${address}: ${currentScore}`);
  console.log("");

  // Create the task
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

  // Compute or use manual score
  let score;
  if (manualScore !== null) {
    score = Math.min(100, Math.max(0, manualScore));
    console.log(`\n2. Using manual score: ${score}`);
  } else {
    console.log("\n2. Analyzing on-chain activity...");
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

    console.log(`   Found ${txCount} txs in blocks ${fromBlock}-${toBlock} -> score ${score}`);
  }

  // Sign and submit
  console.log("\n3. Signing and submitting...");
  const messageHash = ethers.solidityPackedKeccak256(
    ["uint32", "address", "uint16"],
    [taskId, address, score]
  );
  const signature = await wallet.signMessage(ethers.getBytes(messageHash));

  const respondTx = await sm.respondToTask(taskId, score, signature);
  const respondReceipt = await respondTx.wait();
  console.log(`   Tx: ${respondReceipt.hash}`);

  // Verify
  const newScore = await oracle.getScore(address);
  console.log(`\nDone! Score for ${address}: ${currentScore} -> ${newScore}`);

  // Show what the hook would do
  if (newScore >= 80) {
    console.log("Hook action: SWAP REJECTED (BotRejected)");
  } else if (newScore >= 40) {
    console.log("Hook action: 3x fee (9000 pips)");
  } else {
    console.log("Hook action: base fee (3000 pips)");
  }
}

main().catch(console.error);
