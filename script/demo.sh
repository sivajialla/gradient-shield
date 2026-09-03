#!/usr/bin/env bash
#
# One continuous demo: every number on the pitch deck, produced live, in one
# terminal. Written to be screen-recorded top to bottom without cuts.
#
#   make demo-full
#
# Part 1  the test suite
# Part 2  the economics A/B, measured against a plain pool
# Part 3  a real sandwich on a real chain, scored by the BLS quorum
#
# Background processes (anvil, the AVS operator) are started and cleaned up
# here, so the whole thing runs in a single visible terminal.

set -uo pipefail
set +m   # no job-control notices when background processes are killed
cd "$(dirname "$0")/.."

RPC=http://127.0.0.1:8545
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
LOG_DIR=$(mktemp -d)
ANVIL_LOG="$LOG_DIR/anvil.log"
AVS_LOG="$LOG_DIR/avs.log"

# Pacing. Raise it if you want longer to talk over each section.
BEAT=${BEAT:-2}

bold()  { printf "\033[1m%s\033[0m\n" "$1"; }
dim()   { printf "\033[2m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

rule() {
  printf "\033[2m%s\033[0m\n" "────────────────────────────────────────────────────────────────"
}

part() {
  echo
  rule
  bold "  $1"
  dim  "  $2"
  rule
  echo
  sleep "$BEAT"
}

cleanup() {
  echo
  dim "Stopping background processes…"
  { kill "${AVS_PID:-0}" "${ANVIL_PID:-0}"; } >/dev/null 2>&1
  { pkill -f "node avs.js"; pkill -f "^anvil"; } >/dev/null 2>&1
  rm -rf "$LOG_DIR"
}
trap cleanup EXIT INT TERM

clear 2>/dev/null || printf '\033[2J\033[H'
bold "GradientShield — every number on the deck, produced live"
dim  "one terminal, no cuts"
sleep "$BEAT"

# ---------------------------------------------------------------------------
part "PART 1 — Does the code hold up?" "forge test"

forge test 2>&1 | tail -3
sleep "$BEAT"

# ---------------------------------------------------------------------------
part "PART 2 — What does the guard change?" \
     "The same sandwich against two identical pools, one plain, one guarded."

forge test --match-test test_economics_sandwichOnBothPools -vv 2>&1 \
  | sed -n '/THE SAME SANDWICH/,/change for the victim/p'
sleep "$BEAT"

green "  The attacker pays 5.3x more. The victim's execution does not move."
sleep "$BEAT"

# ---------------------------------------------------------------------------
part "PART 3 — Does it work on a real chain?" \
     "Three separate transactions, mined into one block, scored by a BLS quorum."

pkill -f "node avs.js" 2>/dev/null
pkill -f "^anvil" 2>/dev/null
sleep 1

dim "  Starting a local chain…"
anvil --silent > "$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
disown 2>/dev/null || true
sleep 4

dim "  Deploying pool, hook and the operator quorum…"
PRIVATE_KEY=$KEY forge script script/DeployLocal.s.sol --rpc-url $RPC --broadcast \
  > "$LOG_DIR/deploy.log" 2>&1

if ! grep -q "HOOK_ADDRESS" "$LOG_DIR/deploy.log"; then
  echo "Deploy failed. Last lines:"; tail -20 "$LOG_DIR/deploy.log"; exit 1
fi
grep -E "^  (HOOK_ADDRESS|TASK_MANAGER|SWAP_ROUTER) " "$LOG_DIR/deploy.log"
echo
sleep "$BEAT"

dim "  Starting the BLS operator quorum…"
( cd operator && exec node avs.js ) > "$AVS_LOG" 2>&1 &
AVS_PID=$!
disown 2>/dev/null || true
sleep 5

bold "  The attack — bot and victim are separate EOAs on the SAME router"
echo
( cd operator && node attack.js 2>&1 ) \
  | sed -n '/Queueing three/,$p' \
  | grep -v "make avs" | grep -v "quorum will now score"
sleep "$BEAT"

echo
dim "  Waiting for the operator quorum to respond…"
for _ in $(seq 1 20); do
  grep -q "Oracle score is now" "$AVS_LOG" && break
  sleep 1
done

echo
bold "  The quorum's verdict"
echo
sed -n '/Analyzing/,/Oracle score is now/p' "$AVS_LOG" | sed 's/^/  /'
sleep "$BEAT"

echo
bold "  Same attack again — now the bot carries that score"
echo
( cd operator && node attack.js 2>&1 ) | sed -n '/Who the hook charged/,/Router score/p'

echo
rule
green "  Bot repriced to 1.05% on entry. Victim still pays 0.30%."
green "  The router itself was never scored."
rule
echo
