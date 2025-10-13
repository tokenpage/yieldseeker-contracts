.PHONY: build test clean lint lint-fix

build:
	forge build

test:
	forge test -vvv

clean:
	forge clean

lint:
	forge fmt --check

lint-fix:
	forge fmt

deploy-local:
	forge script script/Deploy.s.sol --rpc-url localhost --broadcast

deploy-sepolia:
	forge script script/Deploy.s.sol --rpc-url sepolia --broadcast --verify

deploy-base:
	forge script script/Deploy.s.sol --rpc-url base --broadcast --verify
