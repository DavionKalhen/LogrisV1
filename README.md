# Logris V1 — Leveraged Yield Vaults for Alchemix V3

Logris creates **leveraged yield positions** on top of Alchemix V3. Users deposit underlying tokens (e.g., WETH), and the protocol amplifies their exposure to self-repaying yield through flash loans and automated position management.

## How It Works

```
User deposits WETH
    ↓
Convert WETH → wstETH (via Lido)
    ↓
Deposit wstETH into AlchemistV3
    ↓
Mint alETH debt against collateral
    ↓
Swap alETH → WETH (via Curve)
    ↓
Repeat with flash loan amplification
```

All depositors share a single leveraged position proportionally through ERC4626 vault shares. The yield from the leveraged wstETH position accrues to all share holders — Alchemix's self-repaying mechanism gradually pays down the debt, increasing the net value per share over time.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       LeveragedVault                            │
│                    (ERC4626, per Alchemist)                      │
│  - Holds user deposits (WETH)                                   │
│  - Manages single AlchemistV3 position NFT                      │
│  - Stores default adapters + slippage parameters                │
│  - Enforces minimum slippage on debt swaps (sandwich protection)│
└─────────────────────────┬───────────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────────┐
│                       V3Leverager                               │
│                (Shared across all vaults)                        │
│  - Registry-based adapter approval (owner-controlled)           │
│  - Executes leverage/deleverage via flash loans                 │
│  - Validates adapters before every operation                    │
└─────────────────────────┬───────────────────────────────────────┘
              ┌───────────┼───────────┐
              │           │           │
    ┌─────────▼─────┐ ┌───▼───┐ ┌─────▼─────┐
    │  Converters   │ │ Flash │ │  Swappers  │
    │(ITokenConv.)  │ │ Loan  │ │ (ISwapper) │
    │               │ │Adapters│ │           │
    │ WETHToWstETH  │ │       │ │CurveSwapper│
    │  Converter    │ │Balancer│ │           │
    └───────────────┘ │Aave V3│ └───────────┘
                      │Euler  │
                      └───────┘
```

### Key Design Decisions

- **One leverager, many vaults.** A single `V3Leverager` instance serves all vaults. Adapters are approved via a registry — no need to redeploy when adding new flash loan sources or swap routes.

- **Modular adapters.** Converters (WETH↔wstETH), flash loan providers (Balancer/Aave/Euler), and swappers (Curve alETH↔WETH) are independent contracts behind common interfaces. Any combination can be used per operation.

- **Default + override pattern.** Each vault stores default adapters and slippage parameters. Users can call `leverage()` with defaults, `leverageAtomic()` for a one-call experience, or `leverageWithAdapters()` to override everything.

- **Shared position.** All depositors in a vault share one AlchemistV3 position NFT. Share value tracks the net position value (collateral minus debt, converted to underlying).

## Contract Reference

### LeveragedVault

The main user-facing contract. Inherits ERC4626 for share accounting.

#### Depositing

| Function | Description |
|----------|-------------|
| `depositUnderlying(uint256 amount)` | Deposit WETH (requires ERC20 approval) |
| `depositUnderlying()` payable | Deposit ETH (auto-wraps to WETH) |

Both return the number of vault shares minted. The first depositor receives shares 1:1 with their deposit.

#### Leveraging

| Function | Description |
|----------|-------------|
| `leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin)` | Execute with explicit parameters |
| `leverageAtomic(depositAmount, underlyingSlippageBps, debtSlippageBps)` | One-call convenience — computes all parameters internally |
| `leverageWithAdapters(...)` | Execute with explicit parameters AND custom adapters |

The leverage flow:
1. Convert pool's underlying (WETH) → yield tokens (wstETH)
2. Flash loan additional underlying for amplification
3. Convert flash-loaned underlying → yield tokens
4. Deposit all yield tokens into AlchemistV3
5. Mint debt tokens (alETH) against the collateral
6. Swap debt → underlying to repay flash loan
7. Return surplus to user

**Slippage protection:** The vault enforces minimum slippage on all leverage calls. If the vault's `debtSlippageBasisPoints` is set to 400 (4%), then `debtTradeMin` must be at least `mintAmount * 92/100` (2x the configured slippage as floor). This prevents sandwich attacks where a caller passes `debtTradeMin = 0`.

#### Withdrawing

| Function | Description |
|----------|-------------|
| `withdrawUnderlying(shares, flashLoanAmount, burnAmount, minUnderlyingOut)` | Withdraw with explicit deleverage parameters |
| `withdrawUnderlyingAtomic(shares, underlyingSlippageBps, debtSlippageBps)` | One-call convenience |
| `withdrawUnderlyingWithAdapters(...)` | Withdraw with custom adapters |

Three withdrawal paths depending on the vault state:
1. **Pool has enough:** Direct transfer from the unleveraged pool balance
2. **Free collateral available:** Withdraw from AlchemistV3 without burning debt
3. **Full deleverage:** Flash loan → swap to debt → burn debt → withdraw collateral → convert → repay

#### View Functions

| Function | Returns |
|----------|---------|
| `getDepositPoolBalance()` | WETH sitting in vault (not yet leveraged) |
| `getVaultDepositedBalance()` | Total collateral in AlchemistV3 position |
| `getVaultDebtBalance()` | Current debt in AlchemistV3 position |
| `getVaultRedeemableBalance()` | Net value (pool + collateral - debt) |
| `getDepositCapacity()` | Remaining AlchemistV3 deposit capacity |
| `getBorrowCapacity()` | How much more debt can be minted |
| `getFreeWithdrawCapacity()` | Collateral withdrawable without deleveraging |
| `convertSharesToUnderlyingTokens(shares)` | Underlying value of shares |
| `convertUnderlyingTokensToShares(amount)` | Shares for a given underlying amount |
| `getLeverageParameters(depositAmount)` | Compute all leverage params using vault defaults |
| `getWithdrawUnderlyingParameters(shares)` | Compute all withdraw params using vault defaults |

#### Admin Functions (onlyOwner)

| Function | Description |
|----------|-------------|
| `pause()` / `unpause()` | Emergency pause all deposits, leverage, and withdrawals |
| `setDefaultConverter(address)` | Change the default token converter |
| `setDefaultFlashLoanAdapter(address)` | Change the default flash loan source |
| `setDefaultSwapper(address)` | Change the default debt↔underlying swapper |
| `setDefaultAdapters(converter, flashLoan, swapper)` | Set all three at once |
| `setSlippageParameters(underlyingBps, debtBps)` | Update default slippage tolerance |
| `emergencySweepToken(token, amount, recipient)` | Recover stuck ERC20 tokens |
| `sweepUnknownPosition(tokenId, to)` | Transfer an unexpected position NFT out |

### LeveragedVaultFactory

Deploys new `LeveragedVault` instances with full parameter validation.

```solidity
factory.createVault(
    "lvWSTETH",                    // token name
    "Leveraged wstETH Vault",      // token symbol
    WSTETH,                        // yield token
    WETH,                          // underlying token
    address(alchemist),            // AlchemistV3 address
    address(leverager),            // V3Leverager address
    100,                           // 1% underlying slippage default
    400,                           // 4% debt slippage default (includes peg)
    address(converter),            // default converter
    address(flashLoanAdapter),     // default flash loan adapter
    address(swapper),              // default swapper
    WETH                           // WETH address
);
```

The factory validates all addresses are non-zero contracts, checks slippage bounds, prevents duplicate vaults per yield token, and transfers ownership of the created vault to the caller.

### V3Leverager

Shared leverager that executes leverage/deleverage operations. Uses a registry pattern for adapter approval.

```solidity
// Owner approves adapters
leverager.setConverterApproval(address(converter), true);
leverager.setFlashLoanAdapterApproval(address(balancerAdapter), true);
leverager.setSwapperApproval(address(curveSwapper), true);

// Or batch approve
leverager.batchApprove(converters, flashLoanAdapters, swappers);
```

Every leverage/deleverage call validates that the specified adapters are approved before executing. The leverager uses a state machine (`Idle → Leverage/Deleverage → Idle`) to ensure flash loan callbacks are only processed during active operations.

### Adapters

#### Flash Loan Adapters

| Adapter | Provider | Fee | Constructor |
|---------|----------|-----|-------------|
| `BalancerFlashLoanAdapter` | Balancer V2 Vault | 0% | `(address balancerVault)` |
| `AaveV3FlashLoanAdapter` | Aave V3 Pool | 0.05% | `(address aavePool)` |
| `EulerFlashLoanAdapter` | Euler DTokens | 0% | `(address[] tokens, address[] dTokens)` |

All adapters implement `IFlashLoanAdapter` and include:
- Reentrancy protection (`nonReentrant`)
- Pausability (`pause()` / `unpause()`)
- Emergency withdrawal (`emergencyWithdraw()`)
- Context validation on callbacks (prevents spoofed callbacks)

#### CurveSwapper

Swaps between alETH and WETH via Curve pool. Supports both ETH-native and ERC20 pool variants.

```solidity
swapper = new CurveSwapper(
    CURVE_ALETH_POOL,   // Curve pool address
    ALETH,              // debt token
    WETH,               // underlying token
    1,                  // ETH index in pool
    0,                  // alETH index in pool
    WETH,               // WETH address
    false,              // true if pool uses native ETH
    owner               // owner address
);
```

#### WETHToWstETHConverter

Converts between WETH and wstETH:
- **toYield:** WETH → ETH → stETH (Lido submit) → wstETH
- **toUnderlying:** wstETH → stETH (unwrap) → ETH (Curve swap) → WETH

#### WstETHAdapter

Token adapter for AlchemistV3 integration. Provides price oracle data for wstETH via `stEthPerToken()`.

## Token Flow

### Leverage Operation

```
                    WETH (user deposit)
                         │
                    ┌────▼────┐
                    │Converter│  WETH → wstETH (via Lido)
                    └────┬────┘
                         │
              ┌──────────▼──────────┐
              │   WETH (flash loan) │  From Balancer/Aave/Euler
              └──────────┬──────────┘
                         │
                    ┌────▼────┐
                    │Converter│  WETH → wstETH (via Lido)
                    └────┬────┘
                         │
              ┌──────────▼──────────┐
              │    AlchemistV3      │  Deposit wstETH, mint alETH
              └──────────┬──────────┘
                         │
                    ┌────▼────┐
                    │ Swapper │  alETH → WETH (via Curve)
                    └────┬────┘
                         │
              ┌──────────▼──────────┐
              │  Repay flash loan   │  Return WETH to adapter
              └──────────┬──────────┘
                         │
                    Surplus → User
```

### Deleverage Operation

```
              ┌──────────────────────┐
              │   WETH (flash loan)  │  From Balancer/Aave/Euler
              └──────────┬───────────┘
                         │
                    ┌────▼────┐
                    │ Swapper │  WETH → alETH (via Curve)
                    └────┬────┘
                         │
              ┌──────────▼──────────┐
              │    AlchemistV3      │  Burn alETH, withdraw wstETH
              └──────────┬──────────┘
                         │
                    ┌────▼────┐
                    │Converter│  wstETH → WETH (via Curve stETH/ETH)
                    └────┬────┘
                         │
              ┌──────────▼──────────┐
              │  Repay flash loan   │  Return WETH to adapter
              └──────────┬──────────┘
                         │
                    Surplus → User
```

## Directory Structure

```
src/
├── LeveragedVault.sol              # Main ERC4626 vault
├── LeveragedVaultFactory.sol       # Factory for deploying vaults
├── ERC4626.sol                     # Base ERC4626 implementation
│
├── leveragers/
│   └── V3Leverager.sol             # Modular leverager with registry pattern
│
├── adapters/
│   ├── flashloan/
│   │   ├── BalancerFlashLoanAdapter.sol   # Balancer V2 (0% fee)
│   │   ├── AaveV3FlashLoanAdapter.sol     # Aave V3 (0.05% fee)
│   │   └── EulerFlashLoanAdapter.sol      # Euler Finance (0% fee)
│   ├── CurveSwapper.sol            # alETH ↔ WETH via Curve
│   └── WstETHAdapter.sol           # wstETH token adapter for AlchemistV3
│
├── converters/
│   └── WETHToWstETHConverter.sol   # WETH ↔ wstETH via Lido + Curve
│
├── interfaces/
│   ├── ILeveragerV3.sol            # Leverager interface + structs
│   ├── ILeveragedVault.sol         # Vault interface
│   ├── ILeveragedVaultCallback.sol # Vault callback interface
│   ├── ILeveragedVaultFactory.sol  # Factory interface
│   ├── ITokenConverter.sol         # Converter interface
│   ├── ISwapper.sol                # Swapper interface
│   ├── IERC4626.sol                # ERC4626 interface
│   ├── flashloan/
│   │   ├── IFlashLoanAdapter.sol   # Unified flash loan interface
│   │   └── IFlashLoanCallback.sol  # Flash loan callback interface
│   ├── alchemist/                  # AlchemistV3 interfaces
│   ├── balancer/                   # Balancer V2 interfaces
│   ├── curve/                      # Curve pool interfaces
│   └── euler/                      # Euler Finance interfaces
│
└── config/
    ├── MainnetAddresses.sol        # Mainnet contract addresses
    └── NetworkConfig.sol           # Network configuration helper

test/
├── V3LeveragerModular.t.sol        # V3Leverager unit tests (760 lines)
├── V3LeveragerE2E.t.sol            # E2E tests on mainnet fork (653 lines)
├── IntegrationAndInvariant.t.sol   # Full integration + invariant tests (694 lines)
├── IntegrationFork.t.sol           # Fork integration tests (820 lines)
├── SecurityTests.t.sol             # Security-focused tests (721 lines)
├── FuzzTests.t.sol                 # Fuzz tests for math (506 lines)
├── FlashLoanAdapterFork.t.sol      # Flash loan adapter tests (516 lines)
├── ERC4626.t.sol                   # ERC4626 compliance tests (370 lines)
├── CurveSwapperFork.t.sol          # Curve swapper fork tests (362 lines)
├── LeveragedVaultFactory.t.sol     # Factory validation tests (323 lines)
├── CurveSwapperUnit.t.sol          # Curve swapper unit tests (268 lines)
├── EdgeCases.t.sol                 # Edge case + gas tests (232 lines)
├── VaultPositionInvariant.t.sol    # Position NFT invariant tests (206 lines)
├── UnitMismatchTests.t.sol         # Unit conversion tests (180 lines)
├── LeveragedVaultPause.t.sol       # Pause mechanism tests (118 lines)
└── WETHToWstETHConverterConfig.t.sol # Converter config tests (82 lines)
```

## Building and Testing

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Git (with submodule support)

### Setup

```bash
# Clone with submodules
git clone --recursive <repo-url>
cd LogrisV1

# Install dependencies
forge install
```

### Build

```bash
forge build
```

### Running Tests

```bash
# Run all unit tests (no RPC required)
forge test --no-match-path "test/*Fork*|test/*E2E*"

# Run with verbose output
forge test --no-match-path "test/*Fork*|test/*E2E*" -vv

# Run a specific test contract
forge test --match-contract V3LeveragerModularTest -vv

# Run a specific test function
forge test --match-test test_FullCycle_DepositLeverageWithdraw -vvvv
```

### Fork Tests

Fork tests require an Ethereum mainnet RPC endpoint:

```bash
# Set your RPC URL
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# Run fork tests
forge test --match-path "test/*Fork*" -vv

# Run E2E tests (deploy full stack on fork)
forge test --match-contract V3LeveragerE2ETest -vv

# Run all tests including fork tests
forge test -vv
```

### Test Categories

| Category | Command | Description |
|----------|---------|-------------|
| Unit | `forge test --match-contract V3LeveragerModularTest` | Registry, leverage, deleverage with mocks |
| Fuzz | `forge test --match-contract LeveragedVaultFuzzTest` | Randomized share math, flash loan bounds |
| Integration | `forge test --match-contract FullIntegrationTest` | Full deposit→leverage→withdraw cycle |
| Invariant | `forge test --match-contract ShareValueInvariantTest` | Share value preservation under random ops |
| Security | `forge test --match-contract SecurityTests` | Callback spoofing, slippage, reentrancy |
| Factory | `forge test --match-contract LeveragedVaultFactoryTest` | Input validation, ownership |
| Pause | `forge test --match-contract LeveragedVaultPauseTest` | Pause blocks all operations |
| ERC4626 | `forge test --match-contract ERC4626Test` | Standard compliance |
| E2E | `forge test --match-contract V3LeveragerE2ETest` | Real AlchemistV3 + Curve on fork |

### Test Summary

- **284 tests total**, all passing
- **15 fuzz tests** with 256 runs each for mathematical properties
- **3 invariant tests** with random deposit/withdraw sequences
- **12 E2E tests** on mainnet fork with real protocols
- Automated audit tools run: **Slither** (Trail of Bits) and **Aderyn** (Cyfrin)

## Security Model

### Access Control

| Role | Permissions |
|------|------------|
| **Vault Owner** | Pause/unpause, set default adapters, set slippage, emergency sweep |
| **Leverager Owner** | Approve/revoke adapters in registry |
| **Anyone** | Deposit, withdraw, call leverage/deleverage (with slippage enforcement) |

### Safety Mechanisms

- **Slippage enforcement:** Vault enforces minimum acceptable slippage on debt swaps to prevent sandwich attacks, even when `leverage()` is called with arbitrary parameters
- **Reentrancy protection:** `nonReentrant` on all state-changing functions
- **Concurrent operation guard:** `noConcurrentOperation` modifier prevents overlapping leverage/deleverage
- **Flash loan callback validation:** State machine + initiator + caller checks prevent spoofed callbacks
- **Adapter registry:** Only owner-approved adapters can be used by the leverager
- **Pausable:** Owner can halt all vault operations in emergencies
- **Emergency sweep:** Owner can recover stuck tokens from vault, adapters, and converters
- **Position integrity:** Vault validates it owns exactly one AlchemistV3 position NFT

### Automated Audit Results

The codebase has been analyzed with:
- **Slither** (Trail of Bits static analyzer) — all findings addressed
- **Aderyn** (Cyfrin static analyzer) — all findings addressed
- **Forge coverage** — unit, fuzz, integration, and invariant tests

## Mainnet Addresses

| Contract | Address |
|----------|---------|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| alETH | `0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6` |
| Balancer Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Curve alETH/ETH | `0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e` |
| Curve stETH/ETH | `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022` |

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — Access control, SafeERC20, ReentrancyGuard, Pausable
- [Alchemix V3](https://github.com/alchemix-finance) — AlchemistV3, position NFTs (submodule at `alchemix-v3/`)
- [Forge Std](https://github.com/foundry-rs/forge-std) — Testing framework

## License

MIT
