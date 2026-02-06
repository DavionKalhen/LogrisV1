# Local Testing Environment

This guide explains how to run and test the Logris V1 Leveraged Vault system against a local Ethereum mainnet fork with real AlchemistV3 contracts.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Python 3 (for dApp server)
- An Ethereum RPC URL (optional, uses public RPC by default)

## Quick Start

### 1. Start the Local Chain

```bash
# Start Anvil fork with all contracts deployed
./script/start-local.sh
```

This will:
- Start an Anvil instance forking Ethereum mainnet at block 19,500,000
- Deploy the complete AlchemistV3 system
- Deploy the Leverager system (flash loan adapter, swapper, leverager)
- Output all contract addresses

### 2. Start the dApp

In a new terminal:

```bash
# Start the web interface
./dapp/serve.sh
```

Then open http://localhost:3000 in your browser.

## What Gets Deployed

### AlchemistV3 System
- **AlchemistV3**: Core lending/borrowing contract (deployed from source on fork)
- **AlchemistV3Position NFT**: Position tracking NFT
- **Transmuter**: Debt-to-yield conversion system
- **AlchemistTokenVault**: Fee collection vault
- **alETH**: Real mainnet debt token (whitelisted for the forked Alchemist)
- **WstETHAdapter**: Token adapter for real wstETH

### Leverager System
- **BalancerFlashLoanAdapter**: Uses real Balancer V2 for flash loans
- **AaveV3FlashLoanAdapter**: Optional fallback adapter
- **CurveSwapper**: Real Curve alETH/ETH pool swapper
- **WETHToWstETHConverter**: Converts WETH ↔ wstETH via Curve stETH pool
- **V3Leverager**: Modular leverager coordinating flash loan + swaps
- **LeveragedVault + Factory**: ERC4626 vault with single V3 position

## Test Accounts

The local chain comes with pre-funded accounts:

| Account | Address | Private Key |
|---------|---------|-------------|
| Deployer | 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 | 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 |
| Test User 1 | 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 | 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d |
| Test User 2 | 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC | 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a |

Each account starts with 10,000 ETH.

## Manual Testing with Forge

### Run a Leverage Operation

```bash
# Connect to local chain
export RPC_URL=http://localhost:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Example: Create leveraged position
forge script script/TestLeverage.s.sol --rpc-url $RPC_URL --broadcast
```

### Run Integration Tests Against Local Chain

```bash
# Run tests against local fork
forge test --fork-url http://localhost:8545 -vvv
```

## Architecture

```
User
  │
  ▼
LeveragedVault (ERC4626) ◄─────────┐
  │                                │
  │ 1. Request leverage            │
  ▼                                │
V3Leverager                        │
  │                                │
  │ 2. Flash loan                  │
  ▼                                │
FlashLoanAdapter                   │
  │                                │
  │ 3. Receive WETH                │
  │                                │
  │ 4. Convert WETH → wstETH        │
  ▼                                │
WETHToWstETHConverter              │
  │                                │
  │ 5. Deposit wstETH              │
  ▼                                │
AlchemistV3 ──────────────────────►│
  │                                │
  │ 6. Mint alETH                  │
  ▼                                │
CurveSwapper                        │
  │                                │
  │ 7. Swap alETH → WETH          │
  │                                │
  │ 8. Repay flash loan            │
  └────────────────────────────────┘
```

## Configuration Options

### Custom Fork Block

```bash
./script/start-local.sh --block 20000000
```

### Custom Port

```bash
./script/start-local.sh --port 8546
```

### Skip Deployment (use existing)

```bash
./script/start-local.sh --skip-deploy
```

### Run in Background

```bash
./script/start-local.sh --background
```

## Contract Addresses

After deployment, contract addresses are saved to `dapp/src/contracts.json`:

```json
{
  "weth": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  "yieldToken": "0x...",
  "debtToken": "0x...",
  "alchemist": "0x...",
  "positionNFT": "0x...",
  "transmuter": "0x...",
  "feeVault": "0x...",
  "flashLoanAdapter": "0x...",
  "swapper": "0x...",
  "leverager": "0x...",
  "balancerVault": "0xBA12222222228d8Ba445958a75a0704d566BF2C8"
}
```

## Leverage Economics

For a 2x leverage position:
- User deposits: 5 WETH
- Flash loan: 5 WETH
- Total collateral: 10 wstETH
- Debt minted: ~5.05 alETH (to cover swap fees)
- After swap: ~5.02 WETH (0.3% swap fee)
- Flash loan repaid: 5 WETH (Balancer has 0% fee)
- Surplus returned: ~0.02 WETH

Maximum leverage at 80% LTV (111.11% min collateralization):
- Theoretical max: 5x
- Practical max: ~4x (accounting for fees and slippage)

## Troubleshooting

### "Contract not deployed"
Make sure you ran `./script/start-local.sh` and it completed successfully.

### "Insufficient balance"
Use the "Fund Account" button in the dApp or:
```bash
cast send --value 10ether YOUR_ADDRESS --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

### "Transaction reverted"
Check the Anvil logs in `/tmp/anvil.log` or run with `-vvv` for detailed traces.

### "CORS error in browser"
Make sure you're accessing the dApp via `http://localhost:3000`, not `file://`.

## Next Steps

Once testing is complete, the same contracts can be deployed to:
1. Ethereum testnets (Sepolia, Holesky)
2. Ethereum mainnet (after V3 launches)

Remember to:
- Update token addresses for real wstETH/alETH
- Connect to real Curve pools for swaps
- Audit all contracts before mainnet deployment
