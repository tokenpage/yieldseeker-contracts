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

clean:
	@ forge clean
	@ rm -rf cache out

.PHONY: *
