.PHONY: test

build:
	forge build

#forge test --fork-url %ALCHEMY_KEY% -vvvv --mt testGetMethods
test:
	forge test --fork-url ${ALCHEMY_KEY} -vvvv

testnet:
	anvil --fork-url ${ALCHEMY_KEY} --fork-block-number 16900000 --fork-chain-id 1337

localdeploy:
	forge script DeployScript --rpc-url http://localhost:8545 --broadcast --account deployer

leverage:
	forge script Leverage --rpc-url http://localhost:8545 --broadcast --account deployer