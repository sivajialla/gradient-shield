# GradientShield

A Uniswap v4 hook that prices swaps by the swapper's MEV-risk score and emits
telemetry for an off-chain EigenLayer AVS to consume. Suspicious swappers pay an
escalated fee; confirmed toxic flow is rejected outright.

# Project Number : HK-UHI10-1050

> **Status: scaffold.** The project structure, contract interfaces, events,
> errors, hook permissions, and the deployment/test harness are in place and
> `forge build` / `forge test` pass. The actual fee math, JIT/sandwich
> heuristics, score decay, and AVS signature verification are stubbed out and
> marked with `TODO`. See [What to build next](#what-to-build-next).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

## Build & test

```bash
make build       # forge build
make test        # forge test -vvv
make sim         # run just the sandwich-bot escalation demo
```

Most tests currently `vm.skip(true)` — they are stubs describing the behaviour
to implement. Two `ScoringOracle` access-control tests already pass; everything
that needs the v4 pool fixtures or unimplemented logic is skipped for now.

## Repository layout

```
.
├── src/
│   ├── GradientShield.sol      the hook contract
│   └── ScoringOracle.sol       per-address score store
├── test/
│   ├── HookBehavior.t.sol      hook-mechanics tests
│   ├── MEVAttackDefense.t.sol  sandwich / JIT / bot-escalation tests
│   └── ScoringOracle.t.sol     scoring + access-control tests
├── script/
│   └── Deploy.s.sol            CREATE2 deploy with hook-address mining
├── lib/                        git-submodule dependencies (pinned, see below)
├── foundry.toml                Foundry project config
├── remappings.txt              import-path aliases
├── foundry.lock                exact dependency commits
├── Makefile                    common commands (make help)
├── .gitignore                  ignores out/, cache/, .env, etc.
└── README.md                   this file
```

### File-by-file

#### `src/GradientShield.sol` — the hook

The Uniswap v4 hook itself. Extends `BaseHook` (from v4-periphery) and is the
contract a pool points at.

- **Config constants** — `SUSPICIOUS_THRESHOLD` (40), `REJECT_THRESHOLD` (80),
  `ESCALATION_MULTIPLIER` (3), `BASE_FEE` (3000 pips = 0.30%). These define the
  fee ladder below.
- **State** — an immutable reference to the `ScoringOracle`, plus
  `_lastSwapBlock[poolId][swapper]` bookkeeping used by the (TODO) sandwich
  heuristic.
- **`getHookPermissions()`** — declares which v4 callbacks are active:
  `beforeSwap`, `beforeAddLiquidity`, `beforeRemoveLiquidity`. These flags must
  match the deployed address (see `Deploy.s.sol`).
- **`_beforeSwap(...)`** — the core logic. Reads the caller's score from the
  oracle, then: rejects (`revert BotRejected`) at/above `REJECT_THRESHOLD`,
  charges 3× fee (`FeeEscalated`) at/above `SUSPICIOUS_THRESHOLD`, emits
  `SwapTelemetry` on every swap, and returns the fee as a dynamic-fee override.
  Sandwich detection is a marked `TODO` here.
- **`_beforeAddLiquidity` / `_beforeRemoveLiquidity`** — pass-throughs today;
  the entry points for the (TODO) JIT-liquidity heuristic.
- **Events** — `SwapTelemetry`, `SandwichDetected`, `JITDetected`,
  `FeeEscalated`, `BotRejectedEvent` (the last is the log; `BotRejected` is the
  revert error).
- **Errors** — `BotRejected(swapper, score)`.

#### `src/ScoringOracle.sol` — the score store

Holds one MEV-risk score (0–100) per address, written by the AVS and read by
the hook.

- **`ScoreRecord` struct** — `{ uint16 score; uint40 lastUpdated; }` packed into
  one slot.
- **Constants** — `MAX_SCORE` (100), `DECAY_PER_DAY` (5), `ONE_DAY`.
- **Storage** — `_records` mapping, plus `avs` (authorised writer) and `owner`.
- **Writes (AVS-gated)** — `setScore(subject, score)` sets an absolute value;
  `bumpScore(subject, delta)` is meant to add to the live score and saturate at
  `MAX_SCORE` (currently a `TODO` that reverts).
- **Reads** — `getScore(subject)` should apply linear daily decay (currently
  returns the raw stored score — decay is a `TODO`); `rawRecord(subject)`
  returns the undecayed record for indexers.
- **Admin** — `setAvs`, `transferOwnership`, guarded by `onlyOwner`.
- **Events / errors** — `ScoreUpdated`, `AvsUpdated`; `NotOwner`, `NotAvs`,
  `ScoreOutOfRange`, `ZeroAddress`.

#### `test/HookBehavior.t.sol` — hook mechanics

Tests that make GradientShield a *valid, correctly-priced* v4 hook, independent
of any attack scenario: `test_permissionsFlags` (declared vs. address flags),
`test_baseFeeForCleanSwapper` (score 0 → base fee), `test_dynamicFeeOverrideApplied`
(the fee override is actually charged). All skipped pending pool fixtures.

#### `test/MEVAttackDefense.t.sol` — MEV attacks

Tests the defenses: `test_sandwichPatternIsDetected`, `test_jitLiquidityIsDetected`,
and the headline `test_sandwichBotSimulation` — the full escalation demo (bot
sandwiches → scored 60 → pays 3× → scored 95 → rejected). All skipped pending
detection logic. Each test body sketches the intended flow in comments.

#### `test/ScoringOracle.t.sol` — scoring in isolation

Unit tests for the oracle with no hook involved. `test_onlyAvsCanSetScore` and
`test_setScoreRejectsOutOfRange` **pass today**; `test_scoreDecaysOverTime` and
`test_bumpScoreSaturatesAtMax` are skipped until decay/bump are implemented.

#### `script/Deploy.s.sol` — deployment

A `forge script` that deploys the oracle, mines a CREATE2 salt with `HookMiner`
so the hook lands at an address whose low bits encode its permission flags,
deploys `GradientShield` to that mined address, and asserts the address matches.
Reads `POOL_MANAGER` and `PRIVATE_KEY` from the environment. Pool initialisation
and wiring the real AVS ServiceManager are marked `TODO`.

#### Config & tooling

- **`foundry.toml`** — solc 0.8.26, Cancun EVM, optimizer on, `ffi = true` (the
  hook-address mining needs it), and `fs_permissions` for broadcast files.
- **`remappings.txt`** — maps `@uniswap/v4-core/`, `@uniswap/v4-periphery/`,
  `forge-std/`, `solmate/`, and `@openzeppelin/contracts/` onto the `lib/` tree.
- **`foundry.lock`** — records the exact dependency commits (see below).
- **`Makefile`** — thin wrappers over the forge commands; run `make help`.
- **`lib/`** — `forge-std`, `v4-core`, `v4-periphery` as git submodules, pinned
  to the commits below.

## Dependency versions (important)

This scaffold pins specific commits rather than using bare `forge install`
tags, because the moving parts have to agree:

| Dependency     | Pinned rev  | Why                                                            |
| -------------- | ----------- | ------------------------------------------------------------- |
| `v4-core`      | `59d3ecf`   | Has `types/PoolOperation.sol` (`SwapParams`, `ModifyLiquidityParams`). |
| `v4-periphery` | `3779387`   | Last commit that still ships `src/utils/BaseHook.sol` (removed in #510). |
| `forge-std`    | `v1.16.2`   | —                                                             |

`v4-periphery` `main` moved `BaseHook` out to a separate hooks repo, and the
latest `v4-core` release tag (`v4.0.0`) predates the `PoolOperation.sol` split,
so the two no longer compile together out of the box. The pins above are a
matched pair. They are recorded in `foundry.lock`; re-running `forge install`
without arguments will respect them.

Because the deps are submodules, clone recursively:

```bash
git clone --recurse-submodules https://github.com/sivajialla/gradient-shield.git
# already cloned? then:
make install    # git submodule update --init --recursive && forge install
```

## Score → fee ladder

| Score    | Behaviour                                            |
| -------- | ---------------------------------------------------- |
| 0–39     | Base dynamic fee                                     |
| 40–79    | Base fee × 3 (`FeeEscalated` emitted)                |
| 80–100   | Swap reverts with `BotRejected` (`BotRejectedEvent`) |

## Deploy to testnet

```bash
export POOL_MANAGER=<pool_manager_address_on_target_chain>
export PRIVATE_KEY=<your_private_key>
export RPC_URL=<testnet_rpc_url>

make deploy
# or directly:
forge script script/Deploy.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## What to build next

1. Implement the `TODO`s in `ScoringOracle` (linear decay, `bumpScore`) and
   `GradientShield` (sandwich/JIT heuristics, fee override guard).
2. Wire the v4 test fixtures (`Deployers`, `HookMiner`) and un-skip the tests,
   starting with `test_sandwichBotSimulation`.
3. Connect `ScoringOracle` to an EigenLayer ServiceManager for real AVS
   signature verification (replace the single `onlyAvs` writer).
4. Build the AVS operator node (TypeScript) that indexes `SwapTelemetry` events
   and computes scores.
5. Deploy to Base Sepolia or Unichain Sepolia and record the escalation demo.
