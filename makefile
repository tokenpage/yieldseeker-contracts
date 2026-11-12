install:
	@ foundryup --install v1.9.0
	@ forge install

install-updates:
	@ foundryup
	@ forge install

list-outdated:
	@ echo "Not Supported"

lint-check:
	@ forge fmt --check

lint-check-ci:
	@ forge fmt --check

lint-fix:
	@ forge fmt

type-check:
	@ forge build --force

type-check-ci:
	@ forge build

security-check:
	@ echo "Not Supported"

security-check-ci:
	@ echo "Not Supported"

build:
	@ forge build

start:
	@ echo "Not Supported"

start-prod:
	@ echo "Not Supported"

test:
	@ forge test -vvv

test-fork:
	@ forge test --fork-url http://127.0.0.1:8545 --match-path "test/fork/*.sol" -vvv

test-deep:
	@ FOUNDRY_PROFILE=deep forge test --match-path "test/{fuzz,invariant}/**" -vv

prove-halmos:
	@ for suite in FeeAccountingHalmos BorrowSwapHalmos UserOpSignatureHalmos PriceOracleHalmos; do \
		halmos --root . --function check_ --match-contract "^$$suite$$" --loop 2 --solver-timeout-branching 5s --solver-timeout-assertion 60s --storage-layout solidity || exit 1; \
	done

prove-certora:
	@ . certora/env.sh && test -f "$$CERTORA/emv.jar" && for conf in yield-fees borrow-fees borrow-debt-invariant fee-tracker wallet-authorization; do \
		certoraRun.py certora/$$conf.conf --build_dir "$$CERTORA/runs/$$conf-$$(date +%s)" || exit 1; \
	done

test-mutation:
	@ RESULTS_DIR="$${RESULTS_DIR:-/tmp/yieldseeker-mutation}" test/mutation/run.sh all

clean:
	@ forge clean
	@ rm -rf cache out

.PHONY: *
