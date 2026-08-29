import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const smAbi = JSON.parse(readFileSync(join(__dirname, "abi/ServiceManager.json"), "utf8"));

const { RPC_URL, OPERATOR_PRIVATE_KEY, SERVICE_MANAGER_ADDRESS } = process.env;

if (!RPC_URL || !OPERATOR_PRIVATE_KEY || !SERVICE_MANAGER_ADDRESS) {
  console.error("Missing env vars. Copy .env.example to .env and fill in the values.");
  process.exit(1);
}

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(OPERATOR_PRIVATE_KEY, provider);
const sm = new ethers.Contract(SERVICE_MANAGER_ADDRESS, smAbi, wallet);

async function main() {
  const address = process.argv[2];
  if (!address || !ethers.isAddress(address)) {
    console.log("Usage: node createTask.js <address> [fromBlock] [toBlock]");
    console.log("  <address>   - The address to score");
    console.log("  [fromBlock] - Start of observation window (default: current - 100)");
    console.log("  [toBlock]   - End of observation window (default: current)");
    console.log("");
    console.log("Example: node createTask.js 0x1234...abcd");
    process.exit(1);
  }

  const currentBlock = await provider.getBlockNumber();
  const fromBlock = process.argv[3] ? parseInt(process.argv[3]) : Math.max(0, currentBlock - 100);
  const toBlock = process.argv[4] ? parseInt(process.argv[4]) : currentBlock;

  console.log(`Creating score task:`);
  console.log(`  Address:    ${address}`);
  console.log(`  From block: ${fromBlock}`);
  console.log(`  To block:   ${toBlock}`);

  const tx = await sm.createScoreTask(address, fromBlock, toBlock);
  const receipt = await tx.wait();

  // Parse the taskId from the event
  const event = receipt.logs.find((log) => {
    try {
      return sm.interface.parseLog(log)?.name === "ScoreTaskCreated";
    } catch {
      return false;
    }
  });

  if (event) {
    const parsed = sm.interface.parseLog(event);
    console.log(`  Task ID:    ${parsed.args.taskId}`);
  }

  console.log(`  Tx hash:    ${receipt.hash}`);
  console.log(`\nTask created. If the operator is running, it will pick this up automatically.`);
}

main().catch(console.error);
