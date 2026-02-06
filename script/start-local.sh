#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Logris V1 Local Fork Environment${NC}"
echo -e "${BLUE}========================================${NC}"

# Check for required tools
if ! command -v anvil &> /dev/null; then
    echo -e "${RED}Error: anvil not found. Please install Foundry.${NC}"
    exit 1
fi

if ! command -v forge &> /dev/null; then
    echo -e "${RED}Error: forge not found. Please install Foundry.${NC}"
    exit 1
fi

# Configuration
FORK_URL="${ETH_RPC_URL:-https://eth-mainnet.g.alchemy.com/v2/demo}"
FORK_BLOCK="${FORK_BLOCK:-19500000}"
CHAIN_ID="31337"
PORT="8545"

# Default test account (Anvil account 0)
DEPLOYER_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Parse arguments
SKIP_DEPLOY=false
BACKGROUND=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --background|-b)
            BACKGROUND=true
            shift
            ;;
        --port|-p)
            PORT="$2"
            shift 2
            ;;
        --block)
            FORK_BLOCK="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --skip-deploy    Skip contract deployment"
            echo "  --background,-b  Run anvil in background"
            echo "  --port,-p PORT   Use specific port (default: 8545)"
            echo "  --block BLOCK    Fork from specific block (default: 19500000)"
            echo "  --help,-h        Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Create dapp directory if it doesn't exist
mkdir -p dapp/src

# Kill any existing anvil process on the port
if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo -e "${YELLOW}Killing existing process on port $PORT...${NC}"
    kill $(lsof -Pi :$PORT -sTCP:LISTEN -t) 2>/dev/null
    sleep 2
fi

echo -e "\n${GREEN}Starting Anvil with Ethereum mainnet fork...${NC}"
echo -e "  Fork URL: ${FORK_URL}"
echo -e "  Fork Block: ${FORK_BLOCK}"
echo -e "  Port: ${PORT}"
echo -e "  Deployer: ${DEPLOYER_ADDRESS}"

# Start anvil
anvil \
    --fork-url "$FORK_URL" \
    --fork-block-number "$FORK_BLOCK" \
    --chain-id "$CHAIN_ID" \
    --port "$PORT" \
    --balance 10000 \
    --accounts 10 &

ANVIL_PID=$!

# Wait for anvil to be ready
echo -e "${YELLOW}Waiting for Anvil to be ready...${NC}"
for i in {1..30}; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:$PORT > /dev/null 2>&1; then
        echo -e "${GREEN}Anvil is ready!${NC}"
        break
    fi
    sleep 1
done

# Deploy contracts
if [ "$SKIP_DEPLOY" = false ]; then
    echo -e "\n${GREEN}Deploying LeveragedVault system...${NC}"
    echo -e "${YELLOW}Using real mainnet: WETH, wstETH, Balancer, Curve${NC}"
    echo -e "${YELLOW}Mocking: AlchemistV3, alETH (not on mainnet yet)${NC}"

    PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" forge script "script/DeployFork.s.sol:DeployFork" \
        --rpc-url "http://localhost:$PORT" \
        --broadcast \
        -vvv

    if [ $? -eq 0 ]; then
        echo -e "\n${GREEN}Deployment successful!${NC}"

        # Whitelist AlchemistV3 on alETH using Anvil impersonation
        if [ -f "dapp/src/contracts.json" ]; then
            ALCHEMIST=$(cat dapp/src/contracts.json | python3 -c "import sys,json; print(json.load(sys.stdin).get('alchemist',''))" 2>/dev/null)
            if [ -n "$ALCHEMIST" ]; then
                echo -e "${YELLOW}Whitelisting AlchemistV3 on alETH...${NC}"
                ALETH_ADMIN="0x8392F6669292fA56123F71949B52d883aE57e225"
                ALETH="0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6"

                # Impersonate admin, fund it, and whitelist
                cast rpc anvil_impersonateAccount $ALETH_ADMIN --rpc-url "http://localhost:$PORT" > /dev/null 2>&1
                cast rpc anvil_setBalance $ALETH_ADMIN 0x56BC75E2D63100000 --rpc-url "http://localhost:$PORT" > /dev/null 2>&1
                cast send $ALETH "setWhitelist(address,bool)" $ALCHEMIST true \
                    --from $ALETH_ADMIN \
                    --rpc-url "http://localhost:$PORT" \
                    --unlocked > /dev/null 2>&1

                # Verify whitelist
                WHITELISTED=$(cast call $ALETH "whiteList(address)(bool)" $ALCHEMIST --rpc-url "http://localhost:$PORT" 2>/dev/null)
                if [ "$WHITELISTED" = "true" ]; then
                    echo -e "${GREEN}AlchemistV3 whitelisted on alETH!${NC}"
                else
                    echo -e "${RED}Warning: Whitelist may have failed${NC}"
                fi
            fi
        fi
    else
        echo -e "\n${RED}Deployment failed. Check logs above.${NC}"
    fi
fi

# Print test accounts
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}  Test Accounts (10000 ETH each)${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Account 0 (Deployer/Owner):"
echo -e "  Address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo -e "  Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo -e "\nAccount 1 (Test User):"
echo -e "  Address: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo -e "  Private Key: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

# Print RPC info
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}  RPC Endpoint${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "HTTP: http://localhost:$PORT"
echo -e "Chain ID: $CHAIN_ID"

# Print contract addresses if deployed
if [ -f "dapp/src/contracts.json" ]; then
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}  Deployed Contracts${NC}"
    echo -e "${BLUE}========================================${NC}"
    cat dapp/src/contracts.json | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print('  Real Mainnet:')
    for key in ['weth', 'wsteth', 'balancerVault', 'curvePool']:
        if key in data:
            print(f'    {key}: {data[key]}')
    print('  Deployed:')
    for key in ['debtToken', 'alchemist', 'leverager', 'vault']:
        if key in data:
            print(f'    {key}: {data[key]}')
except:
    print('  (unable to parse contracts.json)')
" 2>/dev/null || cat dapp/src/contracts.json
fi

echo -e "\n${GREEN}Local fork environment is ready!${NC}"
echo -e "Press Ctrl+C to stop Anvil"

# Wait for anvil
if [ "$BACKGROUND" = false ]; then
    wait $ANVIL_PID
fi
