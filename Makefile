.PHONY: test

build:
	forge build

test:
	forge test --fork-url ${ALCHEMY_KEY} -vv