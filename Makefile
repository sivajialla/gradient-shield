# GradientShield — common tasks
# Usage: `make <target>` (run `make help` to list everything)

# Load env vars from .env if present (POOL_MANAGER, PRIVATE_KEY, RPC_URL, ...)
-include .env
export

.DEFAULT_GOAL := help
.PHONY: help install build test test-verbose sim demo fmt fmt-check clean deploy deploy-sepolia snapshot operator create-task score sizes mine-hook frontend

## help: list available targets
help:
	@echo "GradientShield make targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

# ───────────────────────────────────────────────────────
# Setup
# ───────────────────────────────────────────────────────

## install: fetch all dependencies (forge libs + operator + frontend npm packages)
install:
	git submodule update --init --recursive
	forge install
	cd operator && npm install
	cd frontend && npm install

# ───────────────────────────────────────────────────────
# Build
# ───────────────────────────────────────────────────────

## build: compile all contracts
build:
	forge build

## clean: remove build artifacts (out/, cache/)
clean:
	forge clean

## sizes: print contract sizes (useful to check 24 KB limit)
sizes:
	forge build --sizes

# ───────────────────────────────────────────────────────
# Test
# ───────────────────────────────────────────────────────

## test: run the full test suite (60 tests across 8 suites)
test:
	forge test -vvv

## test-verbose: run the suite with max verbosity (full traces)
test-verbose:
	forge test -vvvv

## sim: run only the sandwich-bot escalation demo
sim:
	forge test --match-test test_sandwichBotSimulation -vvvv

## demo: run the full 5-scenario demo (clean, occasional, bot, reformed, side-by-side)
demo:
	forge test --match-path test/DemoSimulation.t.sol -vvv

## snapshot: write a gas snapshot (.gas-snapshot)
snapshot:
	forge snapshot

# ───────────────────────────────────────────────────────
# Formatting
# ───────────────────────────────────────────────────────

## fmt: format Solidity sources in place
fmt:
	forge fmt

## fmt-check: verify formatting without writing (CI-friendly)
fmt-check:
	forge fmt --check

# ───────────────────────────────────────────────────────
# Deploy
# ───────────────────────────────────────────────────────

## mine-hook: mine the CREATE2 hook address (needs POOL_MANAGER; optional ORACLE, TASK_MANAGER)
mine-hook:
	@test -n "$(POOL_MANAGER)" || (echo "error: POOL_MANAGER is not set" && exit 1)
	forge script script/MineHookAddress.s.sol

## deploy: deploy full stack to a testnet (needs POOL_MANAGER, PRIVATE_KEY, RPC_URL)
deploy:
	@test -n "$(POOL_MANAGER)" || (echo "error: POOL_MANAGER is not set" && exit 1)
	@test -n "$(PRIVATE_KEY)"  || (echo "error: PRIVATE_KEY is not set"  && exit 1)
	@test -n "$(RPC_URL)"      || (echo "error: RPC_URL is not set"      && exit 1)
	forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

## deploy-sepolia: deploy AVS (oracle + TaskManager + ServiceManager) to Sepolia
deploy-sepolia:
	@test -n "$(PRIVATE_KEY)" || (echo "error: PRIVATE_KEY is not set" && exit 1)
	@test -n "$(RPC_URL)"     || (echo "error: RPC_URL is not set"     && exit 1)
	forge script script/DeploySepolia.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

# ───────────────────────────────────────────────────────
# Operator (off-chain AVS node)
# ───────────────────────────────────────────────────────

## operator: start the off-chain AVS operator (watches for score tasks)
operator:
	cd operator && npm run operator

## create-task: manually create a scoring task via the operator CLI
create-task:
	cd operator && npm run create-task

## score: look up a live score from the deployed oracle
score:
	cd operator && npm run score

# ───────────────────────────────────────────────────────
# Frontend (demo UI)
# ───────────────────────────────────────────────────────

## frontend: start the demo UI dev server (http://localhost:5173)
frontend:
	cd frontend && npm run dev
