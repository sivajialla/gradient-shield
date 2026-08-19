# GradientShield — common tasks
# Usage: `make <target>` (run `make help` to list everything)

# Load env vars from .env if present (POOL_MANAGER, PRIVATE_KEY, RPC_URL, ...)
-include .env
export

.DEFAULT_GOAL := help
.PHONY: help install build test test-verbose sim fmt fmt-check clean deploy snapshot

## help: list available targets
help:
	@echo "GradientShield make targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /'

## install: fetch dependencies (forge-std, v4-core, v4-periphery) at pinned revs
install:
	git submodule update --init --recursive
	forge install

## build: compile all contracts
build:
	forge build

## test: run the full test suite
test:
	forge test -vvv

## test-verbose: run the suite with max verbosity (full traces)
test-verbose:
	forge test -vvvv

## sim: run only the sandwich-bot escalation demo
sim:
	forge test --match-test test_sandwichBotSimulation -vvvv

## fmt: format Solidity sources in place
fmt:
	forge fmt

## fmt-check: verify formatting without writing (CI-friendly)
fmt-check:
	forge fmt --check

## snapshot: write a gas snapshot (.gas-snapshot)
snapshot:
	forge snapshot

## clean: remove build artifacts (out/, cache/)
clean:
	forge clean

## deploy: deploy to a testnet (needs POOL_MANAGER, PRIVATE_KEY, RPC_URL in env/.env)
deploy:
	@test -n "$(POOL_MANAGER)" || (echo "error: POOL_MANAGER is not set" && exit 1)
	@test -n "$(PRIVATE_KEY)"  || (echo "error: PRIVATE_KEY is not set"  && exit 1)
	@test -n "$(RPC_URL)"      || (echo "error: RPC_URL is not set"      && exit 1)
	forge script script/Deploy.s.sol --rpc-url $(RPC_URL) --private-key $(PRIVATE_KEY) --broadcast
