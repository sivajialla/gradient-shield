// Run a real same-block sandwich against the deployed GradientShield pool.
//
// Anvil mines one block per transaction by default, which would put each leg
// of the sandwich in its own block and defeat the hook's transient-storage
// detection. So automining is switched off, all three legs are queued, and a
// single block is mined containing them in order — exactly what a builder
// would produce for a real sandwich.
//
//   node attack.js

import { ethers } from "ethers";
import dotenv from "dotenv";
import { readFileSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

dotenv.config();

const __dirname = dirname(fileURLToPath(import.meta.url));
const abi = (n) => JSON.parse(readFileSync(join(__dirname, `abi/${n}.json`), "utf8"));

const {
  RPC_URL,
  AGGREGATOR_PRIVATE_KEY,
  SWAP_ROUTER,
  HOOK_ADDRESS,
  TOKEN0,
  TOKEN1,
  SCORING_ORACLE_ADDRESS,
} = process.env;

for (const [k, v] of Object.entries({ RPC_URL, AGGREGATOR_PRIVATE_KEY, SWAP_ROUTER, HOOK_ADDRESS, TOKEN0, TOKEN1 })) {
  if (!v) {
    console.error(`Missing env var ${k}. Fill in operator/.env from the deploy output.`);
    process.exit(1);
  }
}

const MIN_SQRT_PRICE = 4295128740n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970341n;
const DYNAMIC_FEE_FLAG = 0x800000;

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(AGGREGATOR_PRIVATE_KEY, provider);
const router = new ethers.Contract(SWAP_ROUTER, abi("PoolSwapTest"), wallet);
const hook = new ethers.Contract(HOOK_ADDRESS, abi("GradientShieldHook"), provider);
const oracle = SCORING_ORACLE_ADDRESS
  ? new ethers.Contract(SCORING_ORACLE_ADDRESS, abi("ScoringOracle"), provider)
  : null;

const poolKey = {
  currency0: TOKEN0,
  currency1: TOKEN1,
  fee: DYNAMIC_FEE_FLAG,
  tickSpacing: 60,
  hooks: HOOK_ADDRESS,
};

const settings = { takeClaims: false, settleUsingBurn: false };

function swapParams(zeroForOne, amount) {
  return {
    zeroForOne,
    amountSpecified: -amount, // negative = exact input
    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE : MAX_SQRT_PRICE,
  };
}

async function setAutomine(on) {
  await provider.send("evm_setAutomine", [on]);
}

async function main() {
  console.log("=".repeat(64));
  console.log("SANDWICH ATTACK — same block, against GradientShieldHook");
  console.log("=".repeat(64));
  console.log(`Router: ${SWAP_ROUTER}`);
  console.log(`Hook:   ${HOOK_ADDRESS}`);
  console.log("");

  if (oracle) {
    console.log(`Router's oracle score before: ${Number(await oracle.getScore(SWAP_ROUTER))}`);
  }

  const startBlock = await provider.getBlockNumber();

  console.log("Queueing three legs into one block:");
  await setAutomine(false);

  let nonce = await provider.getNonceHex ? undefined : await wallet.getNonce();

  const front = await router.swap(poolKey, swapParams(true, ethers.parseEther("4")), settings, "0x", {
    nonce: nonce++,
    gasLimit: 1_000_000,
  });
  console.log("  [1] bot front-run    4 token0 → token1");

  const victim = await router.swap(poolKey, swapParams(true, ethers.parseEther("1")), settings, "0x", {
    nonce: nonce++,
    gasLimit: 1_000_000,
  });
  console.log("  [2] victim swap      1 token0 → token1");

  const back = await router.swap(poolKey, swapParams(false, ethers.parseEther("4")), settings, "0x", {
    nonce: nonce++,
    gasLimit: 1_000_000,
  });
  console.log("  [3] bot back-run     4 token1 → token0");

  await provider.send("evm_mine", []);
  await setAutomine(true);

  await Promise.all([front.wait(), victim.wait(), back.wait()]);

  console.log("");
  console.log(`Mined in one block (${startBlock + 1}). Reading hook events…`);
  console.log("");

  // Read the hook's logs for the mined block directly. A plain getLogs on the
  // hook address keeps this independent of indexed-topic filter shapes.
  // toBlock is "latest" rather than a fetched block number because ethers
  // caches getBlockNumber() briefly, which can yield a stale (empty) range.
  const raw = await provider.getLogs({
    address: HOOK_ADDRESS,
    fromBlock: startBlock + 1,
    toBlock: "latest",
  });

  const decoded = [];
  for (const log of raw) {
    try {
      decoded.push(hook.interface.parseLog(log));
    } catch {
      /* not a hook event */
    }
  }

  const count = (name) => decoded.filter((d) => d.name === name).length;

  console.log(`  SandwichDetected:    ${count("SandwichDetected")}`);
  console.log(`  SenderImpactCapped:  ${count("SenderImpactCapped")}`);
  console.log(`  FeeEscalated:        ${count("FeeEscalated")}`);
  console.log("");

  console.log("  Fee charged per leg:");
  for (const d of decoded.filter((x) => x.name === "SwapTelemetry")) {
    const raw_ = d.args[3];
    const amount = ethers.formatEther(raw_ < 0n ? -raw_ : raw_);
    const fee = Number(d.args[5]);
    const flag = fee > 3000 ? "  <-- penalised" : "";
    console.log(
      `    ${d.args[2] ? "buy " : "sell"} ${amount.padStart(8)} -> ${fee} pips (${(fee / 10000).toFixed(2)}%)${flag}`
    );
  }

  const tasks = count("ScoreTaskTriggered");
  console.log("");
  console.log(`  ScoreTaskTriggered:  ${tasks}`);
  if (tasks > 0) {
    console.log("  -> the AVS operator quorum will now score this address.");
    console.log("     Watch the `make avs` terminal.");
  }
}

main().catch(async (e) => {
  await setAutomine(true).catch(() => {});
  console.error(e);
  process.exit(1);
});
