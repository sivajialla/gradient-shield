// Run a real same-block sandwich against the deployed GradientShield pool.
//
// The bot and the victim are separate EOAs trading through the SAME router,
// which is the case that used to defeat the hook: it saw only the router and
// charged the victim for the bot's volume. The hook now resolves the trader,
// so the two are priced independently.
//
// Anvil mines one block per transaction by default, which would put each leg of
// the sandwich in its own block and defeat the block-scoped detection state. So
// automining is switched off, all three legs are queued, and a single block is
// mined containing them in order — what a builder would actually produce.
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

const { RPC_URL, AGGREGATOR_PRIVATE_KEY, SWAP_ROUTER, HOOK_ADDRESS, TOKEN0, TOKEN1, SCORING_ORACLE_ADDRESS } =
  process.env;

for (const [k, v] of Object.entries({ RPC_URL, AGGREGATOR_PRIVATE_KEY, SWAP_ROUTER, HOOK_ADDRESS, TOKEN0, TOKEN1 })) {
  if (!v) {
    console.error(`Missing env var ${k}. Fill in operator/.env from the deploy output.`);
    process.exit(1);
  }
}

// anvil accounts 1 and 2 — funded with ETH out of the box.
const BOT_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const VICTIM_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";

const MIN_SQRT_PRICE = 4295128740n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970341n;
const DYNAMIC_FEE_FLAG = 0x800000;

const ERC20_ABI = [
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
];

// cacheTimeout -1 disables ethers' per-request cache. Without it, repeated
// getTransactionCount / getBlockNumber calls return stale values while several
// transactions are being sent from one account, producing NONCE_EXPIRED errors
// and empty log ranges.
const provider = new ethers.JsonRpcProvider(RPC_URL, undefined, {
  staticNetwork: true,
  cacheTimeout: -1,
});
const funder = new ethers.Wallet(AGGREGATOR_PRIVATE_KEY, provider);
const bot = new ethers.Wallet(BOT_KEY, provider);
const victim = new ethers.Wallet(VICTIM_KEY, provider);

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

const swapParams = (zeroForOne, amount) => ({
  zeroForOne,
  amountSpecified: -amount, // negative = exact input
  sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE : MAX_SQRT_PRICE,
});

const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

// The funder sends several transfers back to back. ethers does not track
// nonces across separate contract instances, so drive it explicitly.
let funderNonce;

/// ethers caches transaction counts per block, which goes stale when several
/// transactions are sent from one account without an intervening query. Every
/// nonce here is therefore read as "pending" and tracked locally.
async function pendingNonce(address) {
  return provider.getTransactionCount(address, "pending");
}

// Idempotent so `make attack` can be re-run against the same deployment.
async function fundTrader(wallet, label) {
  const topUp = ethers.parseEther("200");
  const minBalance = ethers.parseEther("50");

  let traderNonce = await pendingNonce(wallet.address);

  for (const token of [TOKEN0, TOKEN1]) {
    const t = new ethers.Contract(token, ERC20_ABI, funder);

    if ((await t.balanceOf(wallet.address)) < minBalance) {
      await (await t.transfer(wallet.address, topUp, { nonce: funderNonce++ })).wait();
    }

    const asTrader = new ethers.Contract(token, ERC20_ABI, wallet);
    if ((await asTrader.allowance(wallet.address, SWAP_ROUTER)) < minBalance) {
      await (await asTrader.approve(SWAP_ROUTER, ethers.MaxUint256, { nonce: traderNonce++ })).wait();
    }
  }
  console.log(`  ${label.padEnd(6)} ${short(wallet.address)} funded and approved`);
}

async function main() {
  console.log("=".repeat(68));
  console.log("SANDWICH ATTACK — bot and victim share one router");
  console.log("=".repeat(68));
  console.log(`Router: ${SWAP_ROUTER}`);
  console.log(`Hook:   ${HOOK_ADDRESS}`);
  console.log("");

  console.log("Setting up traders:");
  funderNonce = await pendingNonce(funder.address);
  await fundTrader(bot, "bot");
  await fundTrader(victim, "victim");
  console.log("");

  if (oracle) {
    console.log(`Scores before — bot: ${await oracle.getScore(bot.address)}, ` +
      `victim: ${await oracle.getScore(victim.address)}, ` +
      `router: ${await oracle.getScore(SWAP_ROUTER)}`);
    console.log("");
  }

  const startBlock = await provider.getBlockNumber();

  const botRouter = new ethers.Contract(SWAP_ROUTER, abi("PoolSwapTest"), bot);
  const victimRouter = new ethers.Contract(SWAP_ROUTER, abi("PoolSwapTest"), victim);

  console.log("Queueing three transactions into one block:");
  await provider.send("evm_setAutomine", [false]);

  let botNonce = await pendingNonce(bot.address);
  const victimNonce = await pendingNonce(victim.address);

  const front = await botRouter.swap(poolKey, swapParams(true, ethers.parseEther("4")), settings, "0x", {
    nonce: botNonce++,
    gasLimit: 1_000_000,
  });
  console.log("  [1] bot    front-run   4 token0 -> token1");

  const mid = await victimRouter.swap(poolKey, swapParams(true, ethers.parseEther("1")), settings, "0x", {
    nonce: victimNonce,
    gasLimit: 1_000_000,
  });
  console.log("  [2] victim swap        1 token0 -> token1");

  const back = await botRouter.swap(poolKey, swapParams(false, ethers.parseEther("4")), settings, "0x", {
    nonce: botNonce++,
    gasLimit: 1_000_000,
  });
  console.log("  [3] bot    back-run    4 token1 -> token0");

  await provider.send("evm_mine", []);
  await provider.send("evm_setAutomine", [true]);
  await Promise.all([front.wait(), mid.wait(), back.wait()]);

  console.log("");
  console.log(`Mined in one block (${startBlock + 1}). Reading hook events…`);
  console.log("");

  // toBlock is "latest" because ethers caches getBlockNumber() briefly, which
  // can otherwise yield a stale (empty) range.
  const raw = await provider.getLogs({ address: HOOK_ADDRESS, fromBlock: startBlock + 1, toBlock: "latest" });
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

  const label = (addr) =>
    addr.toLowerCase() === bot.address.toLowerCase()
      ? "bot   "
      : addr.toLowerCase() === victim.address.toLowerCase()
        ? "victim"
        : short(addr);

  console.log("  Who the hook charged, and how much:");
  for (const d of decoded.filter((x) => x.name === "SwapTelemetry")) {
    const amt = d.args[3] < 0n ? -d.args[3] : d.args[3];
    const fee = Number(d.args[5]);
    const flag = fee > 3000 ? "  <-- penalised" : "";
    console.log(
      `    ${label(d.args[1])}  ${d.args[2] ? "buy " : "sell"} ${ethers.formatEther(amt).padStart(6)}` +
        ` -> ${String(fee).padStart(5)} pips (${(fee / 10000).toFixed(2)}%)${flag}`
    );
  }

  const sandwichers = decoded.filter((d) => d.name === "SandwichDetected").map((d) => label(d.args[1]));
  if (sandwichers.length) {
    console.log("");
    console.log(`  Flagged for sandwiching: ${sandwichers.join(", ")}`);
  }

  console.log("");
  console.log(`  ScoreTaskTriggered:  ${count("ScoreTaskTriggered")}`);
  if (count("ScoreTaskTriggered") > 0) {
    console.log("  -> the AVS operator quorum will now score that trader.");
    console.log("     Watch the `make avs` terminal.");
  }

  if (oracle) {
    console.log("");
    console.log("  The router itself is never scored:");
    console.log(`    router ${short(SWAP_ROUTER)} score = ${await oracle.getScore(SWAP_ROUTER)}`);
  }
}

main().catch(async (e) => {
  await provider.send("evm_setAutomine", [true]).catch(() => {});
  console.error(e);
  process.exit(1);
});
