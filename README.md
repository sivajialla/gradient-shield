# GradientShield

A Uniswap v4 hook that prices swaps by the swapper's MEV-risk score and emits
telemetry for an off-chain EigenLayer AVS to consume. Suspicious swappers pay an
escalated fee; confirmed toxic flow is rejected outright.

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
forge build
forge test -vvv
```

All four tests currently `vm.skip(true)` — they are stubs describing the
behaviour to implement, including `test_sandwichBotSimulation` (the demo flow).

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

## Project structure

```
src/
  GradientShield.sol    — Hook: beforeSwap fee ladder, telemetry, JIT/sandwich detection hooks
  ScoringOracle.sol     — Per-address score storage with daily decay (AVS-gated writes)
test/
  GradientShield.t.sol  — Stub test suite incl. the sandwich-bot simulation
script/
  Deploy.s.sol          — Testnet deploy with CREATE2 hook-address mining (HookMiner)
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
