# LogrisV1 - Claude Code Context

## Project Overview

LogrisV1 is a DeFi protocol that creates **leveraged yield positions** using Alchemix V3. Users deposit underlying tokens (e.g., WETH), the protocol leverages them via flash loans, and deposits into Alchemix to earn self-repaying yield.

## Architecture

### Core Flow
```
User deposits WETH → Convert to wstETH → Deposit to AlchemistV3 → Mint alETH debt
                                    ↑
                         Flash loan amplifies deposit
```

### Token Architecture
```
Underlying Token (WETH)
        ↓ convert
Yield Token (wstETH) → deposited to Alchemix
        ↓ mint
Debt Token (alETH) → swapped back to repay flash loan
```

### Contract Architecture (Modular V3)

```
┌─────────────────────────────────────────────────────────────────┐
│                      LeveragedVault                              │
│                   (ERC4626, per Alchemist)                       │
│  - Holds user deposits                                           │
│  - Manages single AlchemistV3 position                          │
│  - Default adapters: converter, flashLoanAdapter, swapper       │
└─────────────────────┬───────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────────────────┐
│                      V3Leverager                                 │
│                (Shared across all vaults)                        │
│  - Registry-based adapter approval                              │
│  - Executes leverage/deleverage via flash loans                 │
│  - Owner approves: converters, flashLoanAdapters, swappers      │
└─────────────────────┬───────────────────────────────────────────┘
          ┌───────────┼───────────┐
          │           │           │
┌─────────▼─────┐ ┌───▼───┐ ┌─────▼─────┐
│  Converters   │ │ Flash │ │  Swappers │
│ (ITokenConv.) │ │ Loan  │ │ (ISwapper)│
└───────────────┘ │Adapters│ └───────────┘
                  └────────┘
```

## Key Interfaces

### ILeveragerV3 (src/interfaces/ILeveragerV3.sol)
The main leverager interface using struct parameters:
```solidity
struct LeverageParams {
    address vault;              // LeveragedVault to operate on
    address converter;          // ITokenConverter for underlying↔yield
    address flashLoanAdapter;   // Flash loan source
    address swapper;            // Debt↔underlying swapper
    uint256 depositAmount;      // User's deposit (yield tokens)
    uint256 flashLoanAmount;    // Amount to flash loan
    uint256 mintAmount;         // Debt to mint
    uint256 minSwapOutput;      // Slippage protection
}
```

### ITokenConverter (src/interfaces/ITokenConverter.sol)
Converts between underlying and yield tokens:
- `toYield(amount, recipient, minYieldOut)` - WETH → wstETH
- `toUnderlying(amount, recipient)` - wstETH → WETH

### ISwapper (src/interfaces/ISwapper.sol)
Swaps between debt and underlying tokens:
- `swapDebtToUnderlying(...)` - alETH → WETH
- `swapUnderlyingToDebt(...)` - WETH → alETH

### IFlashLoanAdapter (src/interfaces/flashloan/IFlashLoanAdapter.sol)
Unified interface for flash loan providers:
- `flashLoan(token, amount, recipient, data)`
- `getFlashLoanFee(token, amount)`

## Directory Structure

```
src/
├── LeveragedVault.sol          # Main ERC4626 vault
├── LeveragedVaultFactory.sol   # Factory for deploying vaults
├── ERC4626.sol                 # Base ERC4626 implementation
│
├── leveragers/
│   └── V3Leverager.sol         # Modular leverager (ONLY ONE)
│
├── adapters/
│   ├── flashloan/
│   │   ├── BalancerFlashLoanAdapter.sol  # 0% fee
│   │   ├── AaveV3FlashLoanAdapter.sol    # 0.05% fee
│   │   └── EulerFlashLoanAdapter.sol
│   ├── CurveSwapper.sol        # alETH↔WETH via Curve
│   └── WstETHAdapter.sol       # ITokenAdapter for Alchemix
│
├── converters/
│   └── WETHToWstETHConverter.sol  # WETH↔wstETH via Lido
│
├── interfaces/
│   ├── ILeveragerV3.sol        # Main leverager interface
│   ├── ITokenConverter.sol     # Converter interface
│   ├── ISwapper.sol            # Swapper interface
│   ├── ILeveragedVault.sol
│   ├── ILeveragedVaultCallback.sol
│   ├── flashloan/
│   │   ├── IFlashLoanAdapter.sol
│   │   └── IFlashLoanCallback.sol
│   └── alchemist/              # AlchemistV3 interfaces
│
└── config/
    └── MainnetAddresses.sol    # Mainnet contract addresses
```

## Key Concepts

### Registry Pattern (V3Leverager)
The leverager maintains approval registries for adapters:
```solidity
mapping(address => bool) private _approvedConverters;
mapping(address => bool) private _approvedFlashLoanAdapters;
mapping(address => bool) private _approvedSwappers;
```
Only owner can approve/revoke. Users can use any approved adapter combination.

### Default Adapters (LeveragedVault)
Each vault stores default adapters for convenience:
```solidity
address public defaultConverter;
address public defaultFlashLoanAdapter;
address public defaultSwapper;
```
Users can override per-call via `leverageWithAdapters()`.

### Flash Loan Callback Flow
1. V3Leverager initiates flash loan via adapter
2. Adapter calls `onFlashLoanReceived()` on V3Leverager
3. V3Leverager executes leverage logic:
   - Convert flash-loaned underlying → yield
   - Deposit yield to vault's Alchemist position
   - Mint debt tokens
   - Swap debt → underlying
   - Repay flash loan + return surplus

## Build & Test

```bash
# Build
forge build

# Run tests
forge test

# Run specific test
forge test --match-contract V3LeveragerModularTest -vv

# Deploy to local fork
./script/start-local.sh
```

## Mainnet Addresses

Key addresses used (see `src/config/MainnetAddresses.sol`):
- WETH: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- wstETH: `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
- alETH: `0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6`
- Balancer Vault: `0xBA12222222228d8Ba445958a75a0704d566BF2C8`
- Curve alETH/ETH: `0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e`
- Aave V3 Pool: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`

## Recent Changes (Feb 2026)

### Modular V3 Architecture Refactor
- **Removed** 6 old leveragers (Leverager.sol, CurveLeverager.sol, etc.)
- **Added** single modular `V3Leverager.sol` with registry pattern
- **Added** `ILeveragerV3` interface with struct-based parameters
- **Added** `ITokenConverter` interface separating conversion from price oracle
- **Added** `WETHToWstETHConverter` for WETH↔wstETH conversion
- **Updated** `LeveragedVault` to use V3 interface with default adapters
- **Updated** `LeveragedVaultFactory` constructor (3 new adapter params)

### Why Modular?
Old architecture required deploying a new leverager for each flash loan source / swap combination. New architecture:
- One shared `V3Leverager` serves all vaults
- Adapters are approved via registry
- Users/vaults can mix-and-match approved adapters
- Easy to add new flash loan sources or swappers

## Testing

Key test files:
- `test/V3LeveragerModular.t.sol` - Tests for modular V3 system
- `test/LeveragedVaultFactory.t.sol` - Factory tests
- `test/FlashLoanAdapterFork.t.sol` - Flash loan adapter tests
- `test/IntegrationFork.t.sol` - Full integration tests

## Dependencies

- OpenZeppelin Contracts
- Alchemix V3 (submodule at `alchemix-v3/`)
- Forge Std (testing)
