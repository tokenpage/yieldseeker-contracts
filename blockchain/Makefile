install:
	@ foundryup

install-updates:
	@ curl -L https://foundry.paradigm.xyz | bash
	@ foundryup

list-outdated:
	@ echo "Not Supported"

lint-check:
	@ forge fmt --check

lint-check-ci:
	@ forge fmt --check

lint-fix:
	@ forge fmt

type-check:
	@ forge build

type-check-ci:
	@ forge build

security-check:
	@ forge test -vvv

security-check-ci:
	@ forge test -vvv

build:
	@ forge build

start:
	@ echo "Not Supported"

start-prod:
	@ echo "Not Supported"

test:
	@ forge test -vvv

test-coverage:
	@ forge coverage

test-gas:
	@ ETH_PRICE=5000; \
	GAS_PRICE=0.01; \
	echo "💰 Gas Report with USD Estimates (ETH @ \$$${ETH_PRICE}, Gas @ $${GAS_PRICE} gwei)"; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	echo ""; \
	forge test --gas-report 2>&1 | tee /tmp/gas-report.txt; \
	echo ""; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	echo "💵 Deployment Costs (USD):"; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	grep "Contract" /tmp/gas-report.txt | while read line; do \
		contract=$$(echo "$$line" | sed 's/.*src\///; s/\.sol.*//; s/:/ - /; s/ Contract.*//'); \
		gas=$$(grep -A4 "$$line" /tmp/gas-report.txt | grep "| [0-9]" | head -1 | awk '{print $$2}'); \
		if [ ! -z "$$gas" ] && [ $$gas -gt 10000 ] 2>/dev/null; then \
			usd=$$(echo "scale=4; $$gas * $$GAS_PRICE * $$ETH_PRICE / 1000000000" | bc -l); \
			printf "  %-40s %10s gas → \$$%s\n" "$$contract" "$$gas" "$$usd"; \
		fi; \
	done; \
	echo ""; \
	echo "💵 Common Operations (USD):"; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	gas=$$(grep "createAgentWallet" /tmp/gas-report.txt | grep "| [0-9]" | awk '{print $$8}' | head -1); \
	if [ ! -z "$$gas" ] && [ $$gas -gt 0 ] 2>/dev/null; then \
		usd=$$(echo "scale=4; $$gas * $$GAS_PRICE * $$ETH_PRICE / 1000000000" | bc -l); \
		printf "  %-40s %10s gas → \$$%s\n" "Create Agent Wallet (median)" "$$gas" "$$usd"; \
	fi; \
	gas=$$(grep "grantRole" /tmp/gas-report.txt | grep "| [0-9]" | awk '{print $$8}' | head -1); \
	if [ ! -z "$$gas" ] && [ $$gas -gt 0 ] 2>/dev/null; then \
		usd=$$(echo "scale=4; $$gas * $$GAS_PRICE * $$ETH_PRICE / 1000000000" | bc -l); \
		printf "  %-40s %10s gas → \$$%s\n" "Grant Role (median)" "$$gas" "$$usd"; \
	fi; \
	gas=$$(grep "emergencyWithdraw" /tmp/gas-report.txt | grep "| [0-9]" | awk '{print $$8}' | head -1); \
	if [ ! -z "$$gas" ] && [ $$gas -gt 0 ] 2>/dev/null; then \
		usd=$$(echo "scale=4; $$gas * $$GAS_PRICE * $$ETH_PRICE / 1000000000" | bc -l); \
		printf "  %-40s %10s gas → \$$%s\n" "Emergency Withdraw (median)" "$$gas" "$$usd"; \
	fi; \
	echo ""; \
	echo "Note: Edit ETH_PRICE and GAS_PRICE variables in Makefile to adjust estimates"

deploy-testnet:
	@ forge script script/DeployDeterministic.s.sol:DeployDeterministic \
		--rpc-url base_sepolia \
		--broadcast \
		--verify

deploy-mainnet:
	@ forge script script/DeployDeterministic.s.sol:DeployDeterministic \
		--rpc-url base \
		--broadcast \
		--verify

clean:
	@ forge clean
	@ rm -rf cache out lib

.PHONY: *
