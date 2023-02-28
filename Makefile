.PHONY: test

build:
	forge build

#forge test --fork-url %ALCHEMY_KEY% -vvvv --mt testGetMethods
test:
	forge test --fork-url ${ALCHEMY_KEY} -vvvv