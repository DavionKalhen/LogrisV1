# Logris V1 — Leveraged Yield Vaults for Alchemix V3

Logris creates **leveraged yield positions** on top of Alchemix V3. Users deposit underlying tokens (e.g., WETH), and the protocol amplifies their exposure to self-repaying yield through flash loans and automated position management.

## How It Works

```
User deposits WETH
    |
    v
Convert WETH -> MYT (via VaultV2 ERC4626 deposit)
    |
    v
Deposit MYT into AlchemistV3 as collateral
    |
    v
Mint alETH debt against collateral
    |
    v
Swap alETH -> WETH (via Curve)
    |
    v
Repeat with flash loan amplification
```

All depositors share a single leveraged position proportionally through ERC4626 vault shares. The yield from the leveraged position accrues to all share holders -- Alchemix's self-repaying mechanism gradually pays down the debt, increasing the net value per share over time.

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
|  - EIP-1153 transient storage for flash loan context         |
|  - Validates adapters + converter token consistency           |
+---------------------------+----------------------------------+
              +-------------+-------------+
              |             |             |
    +---------v-----+ +----v----+ +------v------+
    |  Converters   | |  Flash  | |   Swappers  |
    |(ITokenConv.)  | |  Loan   | |  (ISwapper) |
    |               | | Adapters| |             |
    | MYTConverter  | |         | |CurveSwapper |
    |               | |Balancer | |             |
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

- **Modular adapters.** Converters (WETH<->MYT via VaultV2), flash loan providers (Balancer/Aave/Euler), and swappers (Curve alETH<->WETH) are independent contracts behind common interfaces. Any combination can be used per operation.

- **Immutable adapter binding.** Each vault's adapters (converter, flash loan, swapper) are set at initialization and cannot be changed. This provides users certainty about what contracts interact with their funds.

- **Shared position.** All depositors in a vault share one AlchemistV3 position NFT. Share value tracks the net position value (collateral minus debt minus earmarked, converted to underlying).

- **Withdrawals always available.** `withdrawUnderlying()` is intentionally NOT gated by `whenNotPaused`. Even if the owner pauses the vault, users can always exit their positions.

- **CEI enforcement.** All three withdrawal paths burn shares before making external calls, following the Checks-Effects-Interactions pattern for reentrancy safety.

- **Repay-based deleverage.** Deleveraging uses `AlchemistV3.repay()` with yield tokens (MYT) instead of burn-based debt destruction. The entire path is deterministic through VaultV2 deposit/redeem -- no DEX swap is needed during withdrawal, eliminating swap slippage risk.

## Contract Reference

### LeveragedVault (1,104 LOC)

The main user-facing contract. Deployed as EIP-1167 clones. Inherits ERC4626 for share accounting.

#### Initialization

Called once by `LeveragedVaultFactory` immediately after cloning:

```solidity
vault.initialize(
    yieldToken_,                    // e.g., MYT (VaultV2 shares)
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

Both return the number of vault shares minted. Protected by `nonReentrant`, `whenNotPaused`, and `noConcurrentOperation`. Calls `alchemist.poke()` before share calculation to sync accrued yield.

#### Leveraging

| Function | Description |
|----------|-------------|
| `leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin, deadline)` | Execute with explicit parameters |
| `leverageAtomic(depositAmount, underlyingSlippageBps, debtSlippageBps, deadline)` | One-call convenience -- computes all parameters internally |

The leverage flow:
1. Convert pool's underlying (WETH) -> yield tokens (MYT) via converter
2. Flash loan additional underlying for amplification
3. Convert flash-loaned underlying -> yield tokens
4. Deposit all yield tokens into AlchemistV3 (creates position on first call)
5. Mint debt tokens (alETH) against the collateral
6. Swap debt -> underlying to repay flash loan
7. Return surplus to caller

Both functions accept a `deadline` parameter (set to 0 to skip) for transaction expiry protection.

**Access control note:** `leverage()` has no access restriction -- any address can call it. See [Known Security Issues](#known-security-issues) for details and mitigations.

#### Withdrawing

| Function | Description |
|----------|-------------|
| `withdrawUnderlying(shares, flashLoanAmount, repayAmount, minUnderlyingOut, deadline)` | Withdraw with explicit deleverage parameters |
| `withdrawUnderlyingAtomic(shares, underlyingSlippageBps, debtSlippageBps, deadline)` | One-call convenience |

Three withdrawal paths depending on vault state:

| Path | Condition | Mechanism |
|------|-----------|-----------|
| **Path 1** | Pool balance >= withdrawal amount | Direct transfer from unleveraged pool |
| **Path 2** | Pool + free Alchemist collateral sufficient | Withdraw from AlchemistV3, convert MYT -> underlying |
| **Path 3** | Full deleverage needed | Flash loan -> convert to MYT -> repay debt -> withdraw freed collateral -> convert to underlying -> repay flash loan |

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
| `pokePosition()` | Sync Alchemist position state (accrues yield) |
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

### LeveragedVaultFactory (116 LOC)

Deploys EIP-1167 minimal proxy clones of `LeveragedVault`.

```solidity
factory.createVault(
    MYT_VAULT,                     // yield token (VaultV2 shares)
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
- Validates converter token consistency (yield/underlying must match)
- Prevents duplicate vaults per `(yieldToken, alchemist)` pair
- Transfers ownership of the created vault to `msg.sender`
- Auto-generates name/symbol from the underlying token (e.g., "Logris Leveraged WETH" / "lvWETH")

### V3Leverager (513 LOC)

Shared leverager that executes leverage/deleverage operations across all vaults. Uses **EIP-1153 transient storage** for flash loan context, saving ~20k gas per operation and eliminating stale-state risks.

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
- **State machine:** `Idle -> Leverage/DeleverageRepay -> Idle` ensures flash loan callbacks are only processed during active operations
- **Callback security:** `onFlashLoanReceived` validates `initiator == address(this)` and `msg.sender == flashLoanAdapter`
- **Deleverage access control:** `deleverageRepay()` requires `msg.sender == params.vault` -- only vaults can initiate deleverage

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

#### CurveSwapper (288 LOC)

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

#### MYTConverter (90 LOC)

Converts between underlying tokens and MYT (VaultV2 shares) via ERC4626 `deposit`/`redeem`. Fully deterministic -- no DEX interaction, no slippage from external markets.

- **toYield:** WETH -> VaultV2.deposit() -> MYT shares
- **toUnderlying:** MYT shares -> VaultV2.redeem() -> WETH

#### WstETHAdapter (204 LOC)

Token adapter for AlchemistV3 integration. Provides:
- `price()`: ETH value per wstETH via `stEthPerToken()`
- `wrap()`: WETH -> ETH -> stETH -> wstETH (with `nonReentrant` protection)
- `unwrap()`: wstETH -> stETH -> WETH via swapper (with `nonReentrant` protection)

## Token Flow

### Leverage Operation

```
                    WETH (user deposit from pool)
                         |
                    +----v----+
                    |Converter|  WETH -> MYT (VaultV2 deposit)
                    +----+----+
                         |
              +----------v----------+
              |   WETH (flash loan) |  From Balancer/Aave/Euler
              +----------+----------+
                         |
                    +----v----+
                    |Converter|  WETH -> MYT (VaultV2 deposit)
                    +----+----+
                         |
              +----------v----------+
              |    AlchemistV3      |  Deposit MYT, mint alETH
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

The deleverage path is fully deterministic -- no DEX swap needed.

```
              +----------------------+
              |   WETH (flash loan)  |  From Balancer/Aave/Euler
              +----------+-----------+
                         |
                    +----v----+
                    |Converter|  WETH -> MYT (VaultV2 deposit)
                    +----+----+
                         |
              +----------v----------+
              |    AlchemistV3      |  Repay debt with MYT,
              |                     |  withdraw freed collateral (MYT)
              +----------+----------+
                         |
                    +----v----+
                    |Converter|  MYT -> WETH (VaultV2 redeem)
                    +----+----+
                         |
              +----------v----------+
              |  Repay flash loan   |  Return WETH to adapter
              +----------+----------+
                         |
                    Surplus -> User
```

## Known Security Issues

### Open Issues

#### `leverage()` has no access control [HIGH -- Deferred]

Anyone can call `leverage()` with parameters of their choosing to leverage the vault's pooled deposits. The vault enforces a minimum slippage floor via `_enforceMinimumSlippage()` to bound the worst-case loss per operation, but an attacker could still:

- Leverage at unfavorable (but within-tolerance) slippage
- Trigger leverage at inopportune market times
- Front-run legitimate leverage calls via MEV

**Mitigations in place:**
- `_enforceMinimumSlippage()` enforces `debtTradeMin >= mintAmount * (10000 - debtSlippageBps) / 10000`
- `deadline` parameter prevents stale transactions from executing
- `whenNotPaused` allows the owner to halt leverage operations
- The vault's pool balance limits the deposit amount available to leverage

**Why deferred:** Adding access control (e.g., `onlyOwner`) would centralize the leverage trigger, creating a single point of failure. The current design allows any keeper or automation to maintain the position. Operators should monitor leverage calls and pause if anomalous activity is detected.

#### Immutable adapter addresses [MEDIUM]

Each vault's `converter`, `flashLoanAdapter`, and `swapper` are set at initialization and cannot be changed. If an adapter is compromised, deprecated, or needs upgrading, the only recourse is to deploy a new vault and migrate users.

This is a deliberate tradeoff: immutability gives depositors certainty about exactly which contracts handle their funds, at the cost of operational flexibility.

#### Position NFT griefing [LOW]

An attacker can transfer AlchemistV3 position NFTs to the vault, causing `_requireSinglePosition()` to revert and temporarily blocking operations. This cannot be fully prevented because:

- AlchemistV3Position is a standard ERC721 with no transfer restrictions
- `transferFrom` does not call `onERC721Received`, so receiver-side rejection is impossible
- An attacker could also mint positions directly to the vault via `alchemist.deposit(amount, vaultAddress, 0)`

**Mitigation:** `sweepUnknownPosition()` allows the owner to remove unwanted position NFTs. When `vaultPositionId == 0` (pre-first-deposit), any position can be swept. When an active position exists, only non-active positions can be swept.

#### `totalAssets()` oracle dependency [INFO]

`totalAssets()` depends on `alchemist.convertYieldTokensToUnderlying()` for the yield token price. For wstETH, this uses Lido's `stEthPerToken()` (~$20B TVL, manipulation-infeasible). **Future yield token integrations MUST use a manipulation-resistant price source** -- AMM spot prices are NOT safe, as flash-loan price manipulation would directly affect share price.

### Resolved Issues

The codebase has undergone two rounds of professional security audit (2026-02-07) plus an additional review (2026-02-23).

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| S-01 | HIGH | `leverage()` has no access control | Deferred (see above) |
| S-02 | MEDIUM | Path 3 over-withdraws when pool balance > 0 | **Fixed** |
| S-03 | MEDIUM | CEI violation: shares burned after external calls | **Fixed** (all paths) |
| S-04 | MEDIUM | Position creation griefing via NFT transfer | **Fixed** |
| S-05 | MEDIUM | Deleverage over-burns debt (favorable swap surplus) | **Fixed** |
| S-06 | MEDIUM | Zero-slippage bypass in `_enforceMinimumSlippage` | **Fixed** |
| M-2 | MEDIUM | Residual yield token approval on Alchemist after repay | **Fixed** |
| M-3 | MEDIUM | WstETHAdapter `wrap()`/`unwrap()` lacked reentrancy guards | **Fixed** |
| L-1 | LOW | Atomic functions didn't validate slippage < 10000 bps | **Fixed** |
| L-3 | LOW | EulerFlashLoanAdapter stored unused `userData` in storage | **Fixed** |
| S-07+ | LOW/INFO | Various low-severity findings | Accepted |

## Safety Mechanisms

| Mechanism | Description |
|-----------|-------------|
| **ERC4626 inflation protection** | `_decimalsOffset() = 3` adds 1000 virtual shares, requiring ~1000x the victim's deposit to execute an inflation attack |
| **Slippage enforcement floor** | `_enforceMinimumSlippage()` prevents callers from passing unreasonably low `debtTradeMin`, even when `leverage()` has no access control |
| **CEI pattern** | All three withdrawal paths burn shares before making external calls |
| **Reentrancy protection** | `nonReentrant` on callback functions and adapters, `noConcurrentOperation` on vault entry points |
| **Flash loan state machine** | V3Leverager uses `Idle/Leverage/DeleverageRepay` states with EIP-1153 transient storage |
| **Callback access control** | `onlyLeverager` modifier on all vault callback functions |
| **Deleverage access control** | `deleverageRepay()` requires `msg.sender == params.vault` |
| **Adapter registry** | Only owner-approved adapters can be used by the leverager |
| **Token consistency** | Leverager validates converter tokens match vault tokens before every operation |
| **Yield sync on deposit** | `alchemist.poke()` called before share calculations to reflect accrued yield |
| **Deadline protection** | `leverage()`, `leverageAtomic()`, `withdrawUnderlying()`, `withdrawUnderlyingAtomic()` accept deadline parameters |
| **Pausable deposits/leverage** | Owner can halt new deposits; withdrawals remain available |
| **Emergency sweep** | Owner can recover stuck tokens (blocks underlying and yield token) and ETH |
| **Position integrity** | `_requireSinglePosition()` ensures the vault owns exactly one position NFT |
| **Position griefing recovery** | `sweepUnknownPosition()` handles NFTs sent to the vault to grief position creation |
| **Approval hygiene** | `forceApprove(0)` after Alchemist repay to revoke residual approvals |
| **Earmarked collateral** | `getVaultRedeemableBalance()` excludes collateral committed to the Alchemist transmuter |
| **Re-initialization prevention** | `_disableInitializers()` in constructor, `initializer` modifier on `initialize()` |

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

Compiler: Solidity 0.8.28 with `via_ir = true` and `optimizer_runs = 200`.

### Running Tests

```bash
# Run all non-fork tests (344 tests, no RPC required)
forge test --no-match-path "test/*{Fork,EdgeCases}*"

# Run with verbose output
forge test --no-match-path "test/*{Fork,EdgeCases}*" -vv

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

# Run all tests including fork
forge test -vv
```

### Test Suite Summary

**344 non-fork tests passing** across 26 test suites.

| Category | Test Contract | Description |
|----------|--------------|-------------|
| Audit Coverage | `AuditCoverage` | Regression tests for all audit findings |
| Unit | `V3LeveragerModular` | Registry, leverage, deleverage with mocks |
| Unit | `AdapterUnit` | WstETHAdapter, Converter, Aave adapter |
| Unit | `CurveSwapperUnit` | Curve swapper isolated tests |
| Unit | `DeleverageUnit` | Deleverage path coverage |
| Unit | `LeverageErrorPaths` | Error path + parameter consistency |
| Fuzz | `FuzzTests` | Randomized share math, flash loan bounds |
| Integration | `IntegrationAndInvariant` | Full deposit -> leverage -> withdraw cycle |
| Integration | `LocalAlchemistV3` | AlchemistV3 stack integration (local, no fork) |
| Integration | `RepayDeleverage` | Repay-based deleverage paths |
| Invariant | `VaultPositionInvariant` | Position NFT + share value invariants |
| Security | `SecurityTests` | Callback spoofing, slippage, reentrancy |
| Factory | `LeveragedVaultFactory` | Input validation, clone deployment, ownership |
| Pause | `LeveragedVaultPause` | Pause blocks deposits/leverage, allows withdrawals |
| Converter | `MYTConverter` | MYTConverter configuration and conversion tests |
| Mismatch | `UnitMismatchTests` | Unit conversion edge cases |
| Fork | `IntegrationFork` | Full integration on mainnet fork |
| Fork | `FlashLoanAdapterFork` | Real Balancer/Aave/Euler flash loans |
| Fork | `CurveSwapperFork` | Real Curve pool swaps |
| Fork | `EdgeCases` | Flash loan adapter edge cases on mainnet fork |

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

## Dependencies

- [OpenZeppelin Contracts v5.x](https://github.com/OpenZeppelin/openzeppelin-contracts) -- Access control, SafeERC20, ReentrancyGuard, Pausable, Clones, Math
- [OpenZeppelin Contracts Upgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) -- Initializable, OwnableUpgradeable, ERC20Upgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable
- [Alchemix V3](https://github.com/alchemix-finance) -- AlchemistV3, AlchemistV3Position NFT (reference dependency at `alchemix-v3/`, not shipped)
- [Forge Std](https://github.com/foundry-rs/forge-std) -- Testing framework

## License

MIT
