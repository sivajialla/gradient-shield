# GradientShield — common tasks
# Usage: `make <target>` (run `make help` to list everything)

# Load env vars from .env if present (POOL_MANAGER, PRIVATE_KEY, RPC_URL, ...)
-include .env
export

# Local demo defaults: anvil account 0.
LOCAL_RPC ?= http://127.0.0.1:8545
LOCAL_KEY ?= 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

.DEFAULT_GOAL := help
.PHONY: help install build clean sizes fmt fmt-check \
        test test-verbose demo demo-bls demo-fee snapshot \
        anvil deploy-local avs attack score keygen \
        deploy deploy-sepolia mine-hook

## help: list available targets
help:
	@echo "GradientShield make targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

# ───────────────────────────────────────────────────────
# Setup
# ───────────────────────────────────────────────────────

## install: fetch all dependencies (forge libs + operator npm packages)
install:
	git submodule update --init --recursive
	forge install
	cd operator && npm install

# ───────────────────────────────────────────────────────
# Build
# ───────────────────────────────────────────────────────

## build: compile all contracts
build:
	forge build

## clean: remove build artifacts (out/, cache/)
clean:
	forge clean

## sizes: print contract sizes (useful to check the 24 KB limit)
sizes:
	forge build --sizes

# ───────────────────────────────────────────────────────
# Test
# ───────────────────────────────────────────────────────

## test: run the full test suite
test:
	forge test

## test-verbose: run the suite with full traces
test-verbose:
	forge test -vvvv

## demo-bls: end-to-end AVS loop with real BLS quorum signatures
demo-bls:
	forge test --match-path test/BLSQuorumIntegration.t.sol -vv

## demo-fee: show the PoolManager charging the escalated fee (read the Swap event)
demo-fee:
	forge test --match-test test_senderVolume_exceedsThresholdEscalatesFee -vvvv

## demo: the 5-scenario reputation walkthrough (clean, occasional, bot, reformed)
demo:
	forge test --match-path test/DemoSimulation.t.sol -vv

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
# Local live demo  (4 terminals: anvil / deploy / avs / attack)
# ───────────────────────────────────────────────────────

## anvil: start a local chain (terminal 1)
anvil:
	anvil

## deploy-local: deploy pool + hook + BLS quorum to anvil (terminal 2)
deploy-local:
	PRIVATE_KEY=$(LOCAL_KEY) forge script script/DeployLocal.s.sol \
		--rpc-url $(LOCAL_RPC) --broadcast
	@echo ""
	@echo "Copy the printed addresses into operator/.env, then run: make avs"

## keygen: regenerate the demo operator BLS keys (operator/keys.json)
keygen:
	cd operator && node blsKeygen.js

## avs: run the BLS operator quorum + aggregator (terminal 3)
avs:
	cd operator && node avs.js

## attack: execute a same-block sandwich against the deployed pool (terminal 4)
attack:
	cd operator && node attack.js

## score: look up an address's live score  (usage: make score ADDR=0x...)
score:
	@test -n "$(ADDR)" || (echo "error: pass ADDR=0x..." && exit 1)
	cd operator && node checkScore.js $(ADDR)

# ───────────────────────────────────────────────────────
# Testnet deploy
# ───────────────────────────────────────────────────────

## mine-hook: mine the CREATE2 hook address (needs POOL_MANAGER)
mine-hook:
	@test -n "$(POOL_MANAGER)" || (echo "error: POOL_MANAGER is not set" && exit 1)
	forge script script/MineHookAddress.s.sol

## deploy: deploy the EigenLayer-backed stack (needs POOL_MANAGER, PRIVATE_KEY, RPC_URL)
deploy:
	@test -n "$(POOL_MANAGER)" || (echo "error: POOL_MANAGER is not set" && exit 1)
	@test -n "$(PRIVATE_KEY)"  || (echo "error: PRIVATE_KEY is not set"  && exit 1)
	@test -n "$(RPC_URL)"      || (echo "error: RPC_URL is not set"      && exit 1)
	forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast

## deploy-sepolia: deploy AVS + hook to Sepolia with mocked EigenLayer infra
deploy-sepolia:
	@test -n "$(PRIVATE_KEY)" || (echo "error: PRIVATE_KEY is not set" && exit 1)
	@test -n "$(RPC_URL)"     || (echo "error: RPC_URL is not set"     && exit 1)
	forge script script/DeploySepolia.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast
