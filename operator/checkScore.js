import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const oracleAbi = JSON.parse(readFileSync(join(__dirname, "abi/ScoringOracle.json"), "utf8"));

const { RPC_URL, SCORING_ORACLE_ADDRESS } = process.env;
const provider = new ethers.JsonRpcProvider(RPC_URL);
const oracle = new ethers.Contract(SCORING_ORACLE_ADDRESS, oracleAbi, provider);

const address = process.argv[2];
if (!address || !ethers.isAddress(address)) {
  console.log("Usage: node checkScore.js <address>");
  process.exit(1);
}

const score = Number(await oracle.getScore(address));
const raw = await oracle.rawRecord(address);

console.log(`Address: ${address}`);
console.log(`Score:   ${score}${Number(raw.score) !== score ? ` (raw ${raw.score}, decayed)` : ""}`);

if (score >= 80) {
  console.log("Band:    REJECTED — swap reverts with BotRejected");
} else if (score >= 40) {
  // Continuous curve: 3000 → 15000 pips across scores 40 → 80.
  const fee = 3000 + ((15000 - 3000) * (score - 40)) / 40;
  console.log(`Band:    SUSPICIOUS — ${Math.round(fee)} pips (${(fee / 10000).toFixed(2)}%)`);
} else {
  console.log("Band:    CLEAN — base fee 3000 pips (0.30%)");
}
