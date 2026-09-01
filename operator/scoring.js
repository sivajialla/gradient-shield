// Event-based MEV risk scoring.
//
// Reads the hook's own on-chain events over the task's block range and turns
// observed attack patterns into a score delta. Every operator runs this
// independently and must arrive at the same number — that agreement is what
// the BLS quorum signature attests to.

export const SCORING = {
  // Detections emitted by the hook
  SANDWICH_DETECTED: 35, // confirmed buy → victim → sell in one block
  JIT_DETECTED: 25, // same-block add → swap → remove liquidity
  IMPACT_FEE_HIT: 30, // sender blew past the per-block volume threshold

  // Behavioural signals derived from SwapTelemetry
  MULTI_POOL_ACTIVITY: 10, // flagged across 3+ pools
  HIGH_FREQUENCY: 15, // 10+ swaps in the range
  ROUND_TRIP_RATIO: 20, // >40% of swaps are buy/sell pairs

  MAX_SCORE: 100,
  MIN_FIRST_OFFENSE: 35, // any detection lands in the suspicious band
};

/**
 * @returns {Promise<number>} score delta to add to the subject's current score
 */
export async function computeScore({ hook, provider, subject, fromBlock, toBlock }) {
  console.log(`  Analyzing ${subject} over blocks ${fromBlock}–${toBlock}…`);

  if (!hook) {
    console.log("  HOOK_ADDRESS not set — cannot read detection events, scoring 0");
    return 0;
  }

  let score = 0;
  const reasons = [];

  const events = await scanHookEvents(hook, subject, fromBlock, toBlock);

  if (events.sandwich > 0) {
    const pts = SCORING.SANDWICH_DETECTED * events.sandwich;
    score += pts;
    reasons.push(`${events.sandwich} sandwich detection(s) → +${pts}`);
  }
  if (events.jit > 0) {
    const pts = SCORING.JIT_DETECTED * events.jit;
    score += pts;
    reasons.push(`${events.jit} JIT detection(s) → +${pts}`);
  }
  if (events.impactFee > 0) {
    const pts = SCORING.IMPACT_FEE_HIT * events.impactFee;
    score += pts;
    reasons.push(`${events.impactFee} volume-threshold breach(es) → +${pts}`);
  }
  if (events.poolsActive >= 3) {
    score += SCORING.MULTI_POOL_ACTIVITY;
    reasons.push(`active in ${events.poolsActive} pools → +${SCORING.MULTI_POOL_ACTIVITY}`);
  }

  const behavior = await analyzeSwapBehavior(hook, subject, fromBlock, toBlock);

  if (behavior.totalSwaps >= 10) {
    score += SCORING.HIGH_FREQUENCY;
    reasons.push(`${behavior.totalSwaps} swaps (high frequency) → +${SCORING.HIGH_FREQUENCY}`);
  }
  if (behavior.roundTripRatio > 0.4 && behavior.totalSwaps >= 4) {
    score += SCORING.ROUND_TRIP_RATIO;
    reasons.push(
      `${(behavior.roundTripRatio * 100).toFixed(0)}% round-trip ratio → +${SCORING.ROUND_TRIP_RATIO}`
    );
  }

  // Any detection at all puts the address in the suspicious band.
  if (score > 0 && score < SCORING.MIN_FIRST_OFFENSE) {
    score = SCORING.MIN_FIRST_OFFENSE;
    reasons.push(`first-offense floor applied → ${SCORING.MIN_FIRST_OFFENSE}`);
  }

  score = Math.min(score, SCORING.MAX_SCORE);

  if (reasons.length === 0) {
    console.log("    (no MEV patterns found in range)");
  } else {
    for (const r of reasons) console.log(`    • ${r}`);
  }
  console.log(`  Score delta: ${score}`);

  return score;
}

async function scanHookEvents(hook, subject, fromBlock, toBlock) {
  const counts = { sandwich: 0, jit: 0, impactFee: 0, poolsActive: 0 };
  const pools = new Set();

  const queries = [
    ["SandwichDetected", "sandwich"],
    ["JITDetected", "jit"],
    ["SenderImpactCapped", "impactFee"],
  ];

  for (const [eventName, field] of queries) {
    try {
      const logs = await hook.queryFilter(hook.filters[eventName](null, subject), fromBlock, toBlock);
      counts[field] = logs.length;
      for (const log of logs) pools.add(log.topics[1]);
    } catch (e) {
      console.log(`  Warning: could not read ${eventName}: ${e.message}`);
    }
  }

  counts.poolsActive = pools.size;
  return counts;
}

async function analyzeSwapBehavior(hook, subject, fromBlock, toBlock) {
  const out = { totalSwaps: 0, roundTripRatio: 0 };

  try {
    const logs = await hook.queryFilter(hook.filters.SwapTelemetry(null, subject), fromBlock, toBlock);
    out.totalSwaps = logs.length;

    // Count buy/sell pairs per pool — a sandwich or a wash trade shows up as a
    // high ratio of matched opposite-direction swaps.
    const perPool = new Map();
    for (const log of logs) {
      const poolId = log.topics[1];
      const decoded = hook.interface.decodeEventLog("SwapTelemetry", log.data, log.topics);
      const zeroForOne = decoded[2];

      if (!perPool.has(poolId)) perPool.set(poolId, { buys: 0, sells: 0 });
      const d = perPool.get(poolId);
      zeroForOne ? d.buys++ : d.sells++;
    }

    let paired = 0;
    for (const [, d] of perPool) paired += Math.min(d.buys, d.sells) * 2;
    if (out.totalSwaps > 0) out.roundTripRatio = paired / out.totalSwaps;
  } catch (e) {
    console.log(`  Warning: could not analyze swap behavior: ${e.message}`);
  }

  return out;
}
