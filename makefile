install:
	@ foundryup
	@ forge install

install-updates:
	@ curl -L https://foundry.paradigm.xyz | bash
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
	@ forge build

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

clean:
	@ forge clean
	@ rm -rf cache out

.PHONY: *
