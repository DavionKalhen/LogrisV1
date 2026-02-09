# Logris V1 — Leveraged Yield Vaults for Alchemix V3

Logris creates **leveraged yield positions** on top of Alchemix V3. Users deposit underlying tokens (e.g., WETH), and the protocol amplifies their exposure to self-repaying yield through flash loans and automated position management.

## How It Works

```
User deposits WETH
    |
Convert WETH -> wstETH (via Lido)
    |
Deposit wstETH into AlchemistV3
    |
Mint alETH debt against collateral
    |
Swap alETH -> WETH (via Curve)
    |
Repeat with flash loan amplification
```

All depositors share a single leveraged position proportionally through ERC4626 vault shares. The yield from the leveraged wstETH position accrues to all share holders -- Alchemix's self-repaying mechanism gradually pays down the debt, increasing the net value per share over time.

## Architecture

> See also: [High-resolution architecture diagram](docs/AlchemixLeveragedVaultsOverview.png) | [PDF overview](docs/Logris-Vaults-Alchemix-Leveraged-Vaults.pdf)

### Overview

```
                     LeveragedVaultFactory
                    (deploys EIP-1167 clones)
                              |
                              v
+-------------------------------------------------------------+
|                      LeveragedVault                          |
|               (ERC4626, EIP-1167 minimal proxy)              |
|  - ERC-7201 namespaced storage (two namespaces)              |
|  - Holds user deposits (WETH) in pool                        |
|  - Manages single AlchemistV3 position NFT                   |
|  - Stores immutable adapters + configurable slippage         |
|  - Enforces minimum slippage floor on debt swaps             |
|  - _decimalsOffset()=3 for inflation attack protection       |
+---------------------------+----------------------------------+
                            |
+---------------------------v----------------------------------+
|                       V3Leverager                            |
|                (Shared across all vaults)                     |
|  - Registry-based adapter approval (owner-controlled)        |
|  - Executes leverage/deleverage via flash loans              |
|  - State machine: Idle -> Leverage/Deleverage -> Idle        |
|  - Validates adapters + converter token consistency           |
+---------------------------+----------------------------------+
              +-------------+-------------+
              |             |             |
    +---------v-----+ +----v----+ +------v------+
    |  Converters   | |  Flash  | |   Swappers  |
    |(ITokenConv.)  | |  Loan   | |  (ISwapper) |
    |               | | Adapters| |             |
    |WETHToWstETH   | |         | |CurveSwapper |
    | Converter     | |Balancer | |             |
    +---------------+ |Aave V3  | +-------------+
                      |Euler    |
                      +---------+
```

### Proxy Clone Pattern

Every `LeveragedVault` is deployed as an **EIP-1167 minimal proxy clone** via `LeveragedVaultFactory`. The factory:

1. Holds a reference to a single `LeveragedVault` implementation contract
2. Calls `Clones.clone(implementation)` to deploy a cheap proxy (~45 bytes)
3. Immediately calls `initialize()` on the clone with vault-specific parameters
4. Registers the clone in its `vaultsByKey` mapping (keyed on `keccak256(yieldToken, alchemist)`)

The implementation contract's constructor calls `_disableInitializers()` to prevent direct initialization. Each clone has its own storage but delegates all calls to the shared implementation bytecode.

### ERC-7201 Namespaced Storage

Because clones share implementation bytecode, storage layout must be carefully managed. The vault uses two **ERC-7201 namespaced storage** slots:

| Namespace | Slot | Contents |
|-----------|------|----------|
| `logris.storage.ERC4626` | `0x6934...9400` | Asset address, underlying decimals |
| `logris.storage.LeveragedVault` | `0x66ff...4600` | Alchemist, leverager, adapters, position ID, slippage params |

This prevents storage collisions between the ERC4626 base and the vault-specific state, and is compatible with OpenZeppelin's upgradeable contracts.

### Key Design Decisions

- **One leverager, many vaults.** A single `V3Leverager` instance serves all vaults. Adapters are approved via a registry -- no need to redeploy when adding new flash loan sources or swap routes.

- **Modular adapters.** Converters (WETH<->wstETH), flash loan providers (Balancer/Aave/Euler), and swappers (Curve alETH<->WETH) are independent contracts behind common interfaces. Any combination can be used per operation.

- **Immutable adapter binding.** Each vault's adapters (converter, flash loan, swapper) are set at initialization and cannot be changed. This provides users certainty about what contracts interact with their funds.

- **Shared position.** All depositors in a vault share one AlchemistV3 position NFT. Share value tracks the net position value (collateral minus debt minus earmarked, converted to underlying).

- **Withdrawals always available.** `withdrawUnderlying()` is intentionally NOT gated by `whenNotPaused`. Even if the owner pauses the vault, users can always exit their positions.

- **CEI enforcement.** All three withdrawal paths burn shares before making external calls, following the Checks-Effects-Interactions pattern for reentrancy safety.

## Contract Reference

### LeveragedVault (1,013 LOC)

The main user-facing contract. Deployed as EIP-1167 clones. Inherits ERC4626 for share accounting.

#### Initialization

Called once by `LeveragedVaultFactory` immediately after cloning:

```solidity
vault.initialize(
    yieldToken_,                    // e.g., wstETH
    underlyingTokenAddress,         // e.g., WETH
    _alchemist,                     // AlchemistV3 contract
    _leverager,                     // V3Leverager contract
    _underlyingSlippageBasisPoints, // e.g., 100 (1%)
    _debtSlippageBasisPoints,       // e.g., 400 (4%)
    _converter,                     // ITokenConverter (immutable)
    _flashLoanAdapter,              // IFlashLoanAdapter (immutable)
    _swapper,                       // ISwapper (immutable)
    _weth,                          // WETH contract
    initialOwner                    // Set by factory to msg.sender
);
```

All address parameters are validated as non-zero. Slippage must be < 10,000 bps. The `initializer` modifier prevents re-initialization.

#### Depositing

| Function | Description |
|----------|-------------|
| `depositUnderlying(uint256 amount)` | Deposit WETH (requires ERC20 approval) |
| `depositUnderlying()` payable | Deposit ETH (auto-wraps to WETH) |

Both return the number of vault shares minted. Protected by `nonReentrant`, `whenNotPaused`, and `noConcurrentOperation`.

#### Leveraging

| Function | Description |
|----------|-------------|
| `leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin)` | Execute with explicit parameters |
| `leverageAtomic(depositAmount, underlyingSlippageBps, debtSlippageBps)` | One-call convenience -- computes all parameters internally |

The leverage flow:
1. Convert pool's underlying (WETH) -> yield tokens (wstETH) via converter
2. Flash loan additional underlying for amplification
3. Convert flash-loaned underlying -> yield tokens
4. Deposit all yield tokens into AlchemistV3 (creates position on first call)
5. Mint debt tokens (alETH) against the collateral
6. Swap debt -> underlying to repay flash loan
7. Return surplus to caller

**Access control note:** `leverage()` has no access restriction -- any address can call it. The vault enforces a minimum slippage floor via `_enforceMinimumSlippage()`: if the vault's `debtSlippageBasisPoints` is 400 (4%), then `debtTradeMin` must be at least `mintAmount * 96/100`. This prevents sandwich attacks where a caller passes `debtTradeMin = 0`. When `debtSlippageBasisPoints = 0`, zero tolerance is enforced (`debtTradeMin >= mintAmount`).

#### Withdrawing

| Function | Description |
|----------|-------------|
| `withdrawUnderlying(shares, flashLoanAmount, burnAmount, minUnderlyingOut)` | Withdraw with explicit deleverage parameters |
| `withdrawUnderlyingAtomic(shares, underlyingSlippageBps, debtSlippageBps)` | One-call convenience |

Three withdrawal paths depending on vault state:

| Path | Condition | Mechanism |
|------|-----------|-----------|
| **Path 1** | Pool balance >= withdrawal amount | Direct transfer from unleveraged pool |
| **Path 2** | Pool + free Alchemist collateral sufficient | Withdraw from AlchemistV3 without burning debt |
| **Path 3** | Full deleverage needed | Flash loan -> swap to debt -> burn debt -> withdraw collateral -> convert -> repay |

All paths burn shares before external calls (CEI pattern). Withdrawals are **not paused** when the vault is paused.

#### View Functions

| Function | Returns |
|----------|---------|
| `getDepositPoolBalance()` | WETH sitting in vault (not yet leveraged) |
| `getVaultDepositedBalance()` | Total collateral in AlchemistV3 position |
| `getVaultDebtBalance()` | Current debt in AlchemistV3 position |
| `getVaultRedeemableBalance()` | Net value: pool + (collateral - earmarked - debt), in underlying |
| `getDepositCapacity()` | Remaining AlchemistV3 deposit capacity |
| `getBorrowCapacity()` | How much more debt can be minted |
| `getFreeWithdrawCapacity()` | Collateral withdrawable without deleveraging |
| `getTotalWithdrawCapacity()` | Total withdrawable collateral (may require deleveraging) |
| `convertSharesToUnderlyingTokens(shares)` | Underlying value of shares |
| `convertUnderlyingTokensToShares(amount)` | Shares for a given underlying amount |
| `getLeverageParameters(depositAmount)` | Compute all leverage params using vault defaults |
| `getWithdrawUnderlyingParameters(shares)` | Compute all withdraw params using vault defaults |

#### Admin Functions (onlyOwner)

| Function | Description |
|----------|-------------|
| `pause()` / `unpause()` | Emergency pause deposits and leverage (withdrawals remain available) |
| `setSlippageParameters(underlyingBps, debtBps)` | Update default slippage tolerance |
| `emergencySweepToken(token, amount, recipient)` | Recover stuck ERC20 tokens (blocks underlying and yield token) |
| `emergencySweepETH(recipient)` | Recover stuck ETH |
| `sweepUnknownPosition(tokenId, to)` | Transfer an unexpected position NFT out (griefing recovery) |

### LeveragedVaultFactory (109 LOC)

Deploys EIP-1167 minimal proxy clones of `LeveragedVault`.

```solidity
factory.createVault(
    WSTETH,                        // yield token
    WETH,                          // underlying token
    address(alchemist),            // AlchemistV3 address
    address(leverager),            // V3Leverager address
    100,                           // 1% underlying slippage default
    400,                           // 4% debt slippage default (includes peg)
    address(converter),            // ITokenConverter
    address(flashLoanAdapter),     // IFlashLoanAdapter
    address(swapper),              // ISwapper
    WETH                           // WETH address
);
```

The factory:
- Validates all addresses are non-zero and have deployed bytecode
- Checks slippage bounds (< 10,000 bps)
- Prevents duplicate vaults per `(yieldToken, alchemist)` pair
- Transfers ownership of the created vault to `msg.sender`
- Auto-generates name/symbol from the underlying token (e.g., "Logris Leveraged WETH" / "lvWETH")

### V3Leverager (463 LOC)

Shared leverager that executes leverage/deleverage operations across all vaults.

```solidity
// Owner approves adapters
leverager.setConverterApproval(address(converter), true);
leverager.setFlashLoanAdapterApproval(address(balancerAdapter), true);
leverager.setSwapperApproval(address(curveSwapper), true);

// Or batch approve
leverager.batchApprove(converters, flashLoanAdapters, swappers);
```

Key behaviors:
- **Registry validation:** Every leverage/deleverage call checks that the specified converter, flash loan adapter, and swapper are approved
- **Token consistency check:** Validates that the converter's `yieldToken()` and `underlyingToken()` match the vault's tokens
- **State machine:** `Idle -> Leverage/Deleverage -> Idle` ensures flash loan callbacks are only processed during active operations
- **Callback security:** `onFlashLoanReceived` validates `initiator == address(this)` and `msg.sender == flashLoanAdapter`
- **Surplus handling:** After deleverage, only `burnAmount` of debt tokens are burned; surplus debt tokens go to the user

### Adapters

#### Flash Loan Adapters

| Adapter | Provider | Fee | Notes |
|---------|----------|-----|-------|
| `BalancerFlashLoanAdapter` | Balancer V2 Vault | 0% | Recommended for most operations |
| `AaveV3FlashLoanAdapter` | Aave V3 Pool | 0.05% (5 bps) | Larger liquidity pool |
| `EulerFlashLoanAdapter` | Euler DTokens | 0% | Token-specific DToken mapping |

All adapters share:
- `IFlashLoanAdapter` interface
- Reentrancy protection (`nonReentrant`)
- Pausability (`pause()` / `unpause()`)
- Emergency withdrawal (`emergencyWithdraw()`)
- Context validation on callbacks (prevents spoofed callbacks)
- Temporary context storage cleared after each operation

#### CurveSwapper (283 LOC)

Swaps between alETH and WETH via Curve pool. Supports both ETH-native and ERC20 pool variants.

```solidity
swapper = new CurveSwapper(
    CURVE_ALETH_POOL,   // Curve pool address
    ALETH,              // debt token
    WETH,               // underlying token
    0,                  // ETH index in pool
    1,                  // alETH index in pool
    WETH,               // WETH address
    true,               // true if pool uses native ETH
    owner               // owner address
);
```

#### WETHToWstETHConverter (205 LOC)

Converts between WETH and wstETH:
- **toYield:** WETH -> ETH (unwrap) -> stETH (Lido submit) -> wstETH (wrap)
- **toUnderlying:** wstETH -> stETH (unwrap) -> ETH (Curve stETH/ETH swap) -> WETH (wrap)

Has a configurable `MIN_OUT_BPS` for minimum output protection and an owner-callable `rescueETH()` for dust recovery.

#### WstETHAdapter (204 LOC)

Token adapter for AlchemistV3 integration. Provides:
- `price()`: ETH value per wstETH via `stEthPerToken()`
- `wrap()`: WETH -> ETH -> stETH -> wstETH
- `unwrap()`: wstETH -> stETH -> WETH (via swapper)

## Token Flow

### Leverage Operation

```
                    WETH (user deposit from pool)
                         |
                    +----v----+
                    |Converter|  WETH -> wstETH (via Lido)
                    +----+----+
                         |
              +----------v----------+
              |   WETH (flash loan) |  From Balancer/Aave/Euler
              +----------+----------+
                         |
                    +----v----+
                    |Converter|  WETH -> wstETH (via Lido)
                    +----+----+
                         |
              +----------v----------+
              |    AlchemistV3      |  Deposit wstETH, mint alETH
              +----------+----------+
                         |
                    +----v----+
                    | Swapper |  alETH -> WETH (via Curve)
                    +----+----+
                         |
              +----------v----------+
              |  Repay flash loan   |  Return WETH to adapter
              +----------+----------+
                         |
                    Surplus -> Caller
```

### Deleverage Operation (Withdraw Path 3)

```
              +----------------------+
              |   WETH (flash loan)  |  From Balancer/Aave/Euler
              +----------+-----------+
                         |
                    +----v----+
                    | Swapper |  WETH -> alETH (via Curve)
                    +----+----+
                         |
              +----------v----------+
              |    AlchemistV3      |  Burn alETH (only burnAmount),
              |                     |  withdraw wstETH
              +----------+----------+
                         |
                    +----v----+
                    |Converter|  wstETH -> WETH (via Curve stETH/ETH)
                    +----+----+
                         |
              +----------v----------+
              |  Repay flash loan   |  Return WETH to adapter
              +----------+----------+
                         |
              +----------v----------+
              | Surplus underlying   |  -> User
              | Surplus debt tokens  |  -> User (if swap was favorable)
              +----------------------+
```

## Adapting to New Alchemist V3 Deployments

The system is designed to support any Alchemist V3 deployment with any debt token and underlying token pair. Here's how to add a new vault type:

### Step 1: Identify the Token Pair

You need:
- **Underlying token**: What users deposit (e.g., WETH, DAI, USDC)
- **Yield token**: What Alchemist accepts as collateral (e.g., wstETH, yvDAI, aUSDC)
- **Debt token**: What Alchemist mints (e.g., alETH, alUSD)

### Step 2: Deploy a Token Converter

Implement `ITokenConverter` for your underlying <-> yield pair:

```solidity
interface ITokenConverter {
    function toYield(uint256 amount, address recipient, uint256 minYieldOut)
        external returns (uint256 yieldAmount);
    function toUnderlying(uint256 amount, address recipient, uint256 minUnderlyingOut)
        external returns (uint256 underlyingAmount);
    function yieldToken() external view returns (address);
    function underlyingToken() external view returns (address);
    function previewToYield(uint256 amount) external view returns (uint256);
    function previewToUnderlying(uint256 amount) external view returns (uint256);
}
```

Example for a DAI/yvDAI pair: the converter would deposit DAI into Yearn to get yvDAI (`toYield`) and withdraw from Yearn to get DAI (`toUnderlying`).

### Step 3: Deploy a Swapper

Implement `ISwapper` for your underlying <-> debt pair:

```solidity
// Must support both directions:
function swapDebtToUnderlying(uint256 debtAmount, uint256 minOut, address recipient, bytes calldata)
    external returns (uint256);
function swapUnderlyingToDebt(uint256 underlyingAmount, uint256 minOut, address recipient, bytes calldata)
    external returns (uint256);
```

This handles the alUSD <-> DAI swap (e.g., via Curve's alUSD pool). The swap route depends on available DEX liquidity for your debt token.

### Step 4: Choose a Flash Loan Adapter

Use an existing adapter if the underlying token has liquidity:
- `BalancerFlashLoanAdapter` (0% fee, if Balancer has liquidity)
- `AaveV3FlashLoanAdapter` (0.05% fee, very deep liquidity)
- `EulerFlashLoanAdapter` (0% fee, token-specific)

Or implement `IFlashLoanAdapter` for a new provider.

### Step 5: Register Adapters and Create Vault

```solidity
// 1. Approve new adapters on the shared leverager
leverager.setConverterApproval(address(newConverter), true);
leverager.setSwapperApproval(address(newSwapper), true);
// Flash loan adapter may already be approved if reusing Balancer/Aave

// 2. Create vault via factory
address vault = factory.createVault(
    yvDAI,                          // yield token
    DAI,                            // underlying token
    address(alchemistV3_USD),       // AlchemistV3 for alUSD
    address(leverager),             // same shared leverager
    50,                             // 0.5% underlying slippage
    200,                            // 2% debt slippage
    address(daiToYvDaiConverter),   // new converter
    address(balancerAdapter),       // existing flash loan adapter
    address(alUsdSwapper),          // new swapper
    DAI                             // "WETH" param is the underlying
);
```

### Step 6: Verify

- The converter's `yieldToken()` must match the vault's yield token
- The converter's `underlyingToken()` must match the vault's underlying token
- The Alchemist must support the yield token as collateral
- The flash loan adapter must have liquidity for the underlying token
- The swapper must handle the debt <-> underlying pair

### Limitations

- Each vault is bound to one (yieldToken, alchemist) pair
- Adapters are immutable per vault after initialization
- The `totalAssets()` oracle depends on `convertYieldTokensToUnderlying()` -- the yield token's price feed must be manipulation-resistant (Lido's stEthPerToken is safe; AMM spot prices are NOT)

## Security Model

### Access Control

| Role | Permissions |
|------|------------|
| **Vault Owner** | Pause/unpause, set slippage, emergency sweep, sweep unknown positions |
| **Leverager Owner** | Approve/revoke adapters in registry |
| **Anyone** | Deposit, withdraw, call leverage/leverageAtomic (with slippage enforcement) |

### Safety Mechanisms

| Mechanism | Description |
|-----------|-------------|
| **ERC4626 inflation protection** | `_decimalsOffset() = 3` adds 1000 virtual shares, requiring ~1000x the victim's deposit to execute an inflation attack |
| **Slippage enforcement floor** | `_enforceMinimumSlippage()` prevents callers from passing unreasonably low `debtTradeMin`, even when `leverage()` has no access control |
| **CEI pattern** | All three withdrawal paths burn shares before making external calls |
| **Reentrancy protection** | `nonReentrant` on callback functions, `noConcurrentOperation` on entry points |
| **Flash loan state machine** | V3Leverager uses `Idle/Leverage/Deleverage` states to reject unexpected callbacks |
| **Callback access control** | `onlyLeverager` modifier on all vault callback functions |
| **Adapter registry** | Only owner-approved adapters can be used by the leverager |
| **Token consistency** | Leverager validates converter tokens match vault tokens before every operation |
| **Pausable deposits/leverage** | Owner can halt new deposits; withdrawals remain available |
| **Emergency sweep** | Owner can recover stuck tokens (blocks underlying and yield token) and ETH |
| **Position integrity** | `_requireSinglePosition()` ensures the vault owns exactly one position NFT |
| **Position griefing recovery** | `sweepUnknownPosition()` handles NFTs sent to the vault to grief position creation |
| **Earmarked collateral** | `getVaultRedeemableBalance()` excludes collateral committed to the Alchemist transmuter |
| **Re-initialization prevention** | `_disableInitializers()` in constructor, `initializer` modifier on `initialize()` |

### Audit Status

The codebase has undergone **two rounds of security audit** (2026-02-07):

**Round 1** (9 findings): All fixed except F-05 (1-wei rounding, LOW) and F-06 (stale interface, LOW).

**Round 2** (14 findings):

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| S-01 | HIGH | `leverage()` has no access control | Deferred (slippage floor mitigates) |
| S-02 | MEDIUM | Path 3 over-withdraws when pool balance > 0 | **Fixed** |
| S-03 | MEDIUM | CEI violation: shares burned after external calls | **Fixed** (all paths) |
| S-04 | MEDIUM | Position creation griefing via NFT transfer | **Fixed** |
| S-05 | MEDIUM | Deleverage over-burns debt (favorable swap surplus) | **Fixed** |
| S-06 | MEDIUM | Zero-slippage bypass in `_enforceMinimumSlippage` | **Fixed** |
| S-07+ | LOW/INFO | Oracle dependency, sweep scope, no deadline | Accepted |

## Directory Structure

```
src/                                    (3,102 LOC across 10 contracts)
|-- LeveragedVault.sol                  (1,013 LOC) Main ERC4626 vault (clone implementation)
|-- LeveragedVaultFactory.sol             (109 LOC) EIP-1167 clone factory
|-- ERC4626Upgradeable.sol                (180 LOC) Custom ERC4626 with ERC-7201 storage
|
|-- leveragers/
|   +-- V3Leverager.sol                   (463 LOC) Modular leverager with registry + state machine
|
|-- adapters/
|   |-- flashloan/
|   |   |-- BalancerFlashLoanAdapter.sol  (226 LOC) Balancer V2 (0% fee)
|   |   |-- AaveV3FlashLoanAdapter.sol    (222 LOC) Aave V3 (0.05% fee)
|   |   +-- EulerFlashLoanAdapter.sol     (197 LOC) Euler Finance (0% fee)
|   |-- CurveSwapper.sol                  (283 LOC) alETH <-> WETH via Curve
|   +-- WstETHAdapter.sol                 (204 LOC) wstETH token adapter for AlchemistV3
|
|-- converters/
|   +-- WETHToWstETHConverter.sol         (205 LOC) WETH <-> wstETH via Lido + Curve
|
|-- interfaces/                           (25 files)
|   |-- ILeveragedVault.sol               Vault interface (deposit, leverage, withdraw)
|   |-- ILeveragedVaultCallback.sol       Callback interface (deposit/mint/withdraw/burn)
|   |-- ILeveragedVaultFactory.sol        Factory interface
|   |-- ILeveragerV3.sol                  Leverager interface + param structs
|   |-- ITokenConverter.sol               Converter interface
|   |-- ISwapper.sol                      Swapper interface
|   |-- IERC4626.sol                      ERC4626 interface
|   |-- flashloan/                        Flash loan adapter + callback interfaces
|   |-- alchemist/                        AlchemistV3 interfaces
|   |-- balancer/                         Balancer V2 interfaces
|   |-- curve/                            Curve pool interfaces
|   +-- euler/                            Euler Finance interfaces
|
+-- config/
    |-- MainnetAddresses.sol              Mainnet contract addresses library
    +-- NetworkConfig.sol                 Network configuration helper

test/                                   (10,018 LOC across 19 test files)
|-- AuditCoverage.t.sol                 (2,049 LOC) Audit fix regression tests + shared mock infra
|-- IntegrationFork.t.sol                 (799 LOC) Fork integration tests
|-- AdapterUnit.t.sol                     (771 LOC) WstETHAdapter, Converter, Aave adapter units
|-- V3LeveragerModular.t.sol              (759 LOC) V3Leverager unit tests with mocks
|-- SecurityTests.t.sol                   (720 LOC) Callback spoofing, slippage, reentrancy
|-- IntegrationAndInvariant.t.sol         (678 LOC) Full cycle integration + invariant tests
|-- V3LeveragerE2E.t.sol                  (595 LOC) E2E tests on mainnet fork
|-- FuzzTests.t.sol                       (509 LOC) Fuzz tests for share math + flash loan bounds
|-- FlashLoanAdapterFork.t.sol            (494 LOC) Flash loan adapter fork tests
|-- DeleverageUnit.t.sol                  (416 LOC) Deleverage path unit tests
|-- LeverageErrorPaths.t.sol              (399 LOC) Leverage error path coverage
|-- LeveragedVaultFactory.t.sol           (374 LOC) Factory validation + ownership tests
|-- CurveSwapperFork.t.sol                (335 LOC) Curve swapper fork tests
|-- CurveSwapperUnit.t.sol                (267 LOC) Curve swapper unit tests
|-- EdgeCases.t.sol                       (222 LOC) Flash loan adapter edge cases (fork)
|-- VaultPositionInvariant.t.sol          (210 LOC) Position NFT invariant tests
|-- UnitMismatchTests.t.sol               (184 LOC) Unit conversion tests
|-- LeveragedVaultPause.t.sol             (151 LOC) Pause mechanism tests
+-- WETHToWstETHConverterConfig.t.sol      (86 LOC) Converter config tests

docs/
|-- alchemix-v3-integration.md           Integration guide
|-- local-testing.md                     Testing guide
+-- MIGRATION_PLAN.md                    Historical: V2 -> V3 migration plan
```

## Building and Testing

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Git (with submodule support)

### Setup

```bash
git clone --recursive <repo-url>
cd LogrisV1
forge install
```

### Build

```bash
forge build
```

Compiler: Solidity 0.8.26 with `via_ir = true` and `optimizer_runs = 200`.

### Running Tests

```bash
# Run all non-fork tests (345 tests, no RPC required)
forge test --no-match-test "Fork|fork"

# Run with verbose output
forge test --no-match-test "Fork|fork" -vv

# Run a specific test contract
forge test --match-contract V3LeveragerModularTest -vv

# Run a specific test function
forge test --match-test test_FullCycle_DepositLeverageWithdraw -vvvv
```

### Fork Tests

Fork tests require an Ethereum mainnet RPC endpoint:

```bash
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# Run fork tests
forge test --match-path "test/*Fork*" -vv

# Run E2E tests (deploy full stack on fork)
forge test --match-contract V3LeveragerE2ETest -vv

# Run all tests including fork
forge test -vv
```

### Test Suite Summary

**345 non-fork tests passing** (7 fork tests require RPC endpoint)

| Category | Test Contract | Tests | Description |
|----------|--------------|-------|-------------|
| Audit Coverage | `AuditCoverage` | 71 | Regression tests for all audit findings |
| Unit | `V3LeveragerModular` | 17 | Registry, leverage, deleverage with mocks |
| Unit | `AdapterUnit` | 62 | WstETHAdapter, Converter, Aave adapter |
| Unit | `CurveSwapperUnit` | 6 | Curve swapper isolated tests |
| Unit | `DeleverageUnit` | 19 | Deleverage path coverage |
| Unit | `LeverageErrorPaths` | 12 | Error path + parameter consistency |
| Fuzz | `LeveragedVaultFuzz` | 15 | Randomized share math, flash loan bounds |
| Integration | `FullIntegration` | 16 | Full deposit -> leverage -> withdraw cycle |
| Invariant | `ShareValueInvariant` | 3 | Share value preservation under random ops |
| Invariant | `VaultPositionInvariant` | 2 | Position NFT integrity |
| Security | `SecurityTests` | 18 | Callback spoofing, slippage, reentrancy |
| Factory | `LeveragedVaultFactory` | 21 | Input validation, clone deployment, ownership |
| Pause | `LeveragedVaultPause` | 9 | Pause blocks deposits/leverage, allows withdrawals |
| Converter | `WETHToWstETHConverterConfig` | 5 | Converter configuration validation |
| Mismatch | `UnitMismatchTests` | 4 | Unit conversion edge cases |
| E2E (fork) | `V3LeveragerE2E` | 12 | Real AlchemistV3 + Curve on mainnet fork |
| Fork | `IntegrationFork` | varies | Full integration on fork |
| Fork | `FlashLoanAdapterFork` | varies | Real Balancer/Aave/Euler flash loans |
| Fork | `CurveSwapperFork` | varies | Real Curve pool swaps |
| Fork | `EdgeCases` | 17 | Flash loan adapter edge cases on mainnet fork |

## Mainnet Addresses

| Contract | Address |
|----------|---------|
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| stETH | `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` |
| alETH | `0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6` |
| Balancer V2 Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` |
| Aave V3 Pool | `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` |
| Curve alETH/ETH | `0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e` |
| Curve stETH/ETH | `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022` |

## Dependencies

- [OpenZeppelin Contracts v5.x](https://github.com/OpenZeppelin/openzeppelin-contracts) -- Access control, SafeERC20, ReentrancyGuard, Pausable, Clones, Math
- [OpenZeppelin Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) -- Initializable, OwnableUpgradeable, ERC20Upgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable
- [Alchemix V3](https://github.com/alchemix-finance) -- AlchemistV3, AlchemistV3Position NFT (reference submodule at `alchemix-v3/`, not shipped)
- [Forge Std](https://github.com/foundry-rs/forge-std) -- Testing framework

## License

MIT
