# Alchemix V3 Integration Guide

This document explains how Logris V1 integrates with Alchemix V3 to create leveraged yield positions. It covers the callback architecture, adapter system, leverage and deleverage flows, and how to extend the system for new token pairs.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [AlchemistV3 Position Model](#alchemistv3-position-model)
3. [Callback Pattern](#callback-pattern)
4. [Adapter System](#adapter-system)
5. [Leverage Flow (Step by Step)](#leverage-flow-step-by-step)
6. [Deleverage Flow (Repay-Based)](#deleverage-flow-repay-based)
7. [Flash Loan Amount Calculation](#flash-loan-amount-calculation)
8. [Creating New Vault Types](#creating-new-vault-types)
9. [Initialization Parameters](#initialization-parameters)
10. [Related Tests](#related-tests)

---

## Architecture Overview

```
User
  |
  v
LeveragedVault (ERC4626, EIP-1167 clone)
  |  Owns single AlchemistV3 position NFT
  |  Manages deposit pool + leveraged position
  |
  |--- leverage() / withdrawUnderlying() --->  V3Leverager (shared, 520 LOC)
  |                                               |
  |<-- callbacks (deposit/mint/withdraw/repay) ---+
  |                                               |
  |                                    +----------+-----------+
  |                                    |          |           |
  |                              Converter  FlashLoan    Swapper
  |                            (ITokenConv) (IFlashLoan) (ISwapper)
  |                                    |          |           |
  |                              WETH<->MYT    Balancer  alETH<->WETH
  |                              (via VaultV2) Aave V3   (via Curve)
  v                                            Euler
AlchemistV3
  |
  +-- Position NFT (ERC-721)
  +-- Collateral (yield tokens, e.g., MYT)
  +-- Debt (debt tokens, e.g., alETH)
  +-- Earmarked collateral (committed to transmuter)
```

The system is designed so that:
- **One leverager serves all vaults.** V3Leverager is deployed once and shared.
- **Adapters are approved via registry.** The leverager owner approves converters, flash loan adapters, and swappers. No redeployment needed.
- **Each vault binds to one adapter set.** At initialization, each vault is permanently linked to a specific converter, flash loan adapter, and swapper. These are immutable.
- **All depositors share one position.** Each vault holds a single AlchemistV3 position NFT. Share value tracks the net position value.
- **EIP-1153 transient storage.** The leverager stores flash loan context in transient storage, saving ~20k gas per operation and eliminating stale-state risks.

---

## AlchemistV3 Position Model

Alchemix V3 uses **NFT-based positions** (ERC-721). Each position has:

| Field | Description |
|-------|-------------|
| `collateral` | Yield tokens deposited (e.g., MYT amount) |
| `debt` | Debt tokens owed (e.g., alETH amount) |
| `earmarked` | Collateral committed to the Alchemist transmuter |

Query a position:
```solidity
(uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(positionId);
```

Key Alchemist V3 functions used by Logris:

| Function | Purpose |
|----------|---------|
| `deposit(amount, recipient, recipientId)` | Deposit yield tokens. Pass `recipientId = 0` to create a new position. |
| `withdraw(amount, recipient, tokenId)` | Withdraw yield tokens from a position. |
| `mint(tokenId, amount, recipient)` | Mint debt tokens against collateral. |
| `approveMint(tokenId, spender, amount)` | Authorize an address to mint from a position. |
| `repay(tokenId, amount)` | Repay debt using yield tokens (MYT). Used during deleverage. |
| `poke(tokenId)` | Sync accrued yield on a position. Called before share calculations. |
| `getCDP(tokenId)` | Query position state (collateral, debt, earmarked). |
| `getMaxBorrowable(tokenId)` | Get remaining borrow capacity. |
| `convertYieldTokensToUnderlying(amount)` | Convert yield token amount to underlying value. |
| `convertUnderlyingTokensToYield(amount)` | Convert underlying amount to yield token equivalent. |
| `normalizeUnderlyingTokensToDebt(amount)` | Convert underlying amount to debt token value. |
| `minimumCollateralization()` | Get required collateral ratio (e.g., 1.111e18 = 111%). |
| `depositCap()` / `getTotalDeposited()` | Global deposit limits. |

---

## Callback Pattern

The vault implements `ILeveragedVaultCallback` to let the leverager interact with its AlchemistV3 position. This is the core architectural pattern: **the leverager never directly touches the Alchemist**. Instead, it calls back into the vault, which performs the privileged operation on its own position.

### Leverage Callback Sequence

```
V3Leverager                                  LeveragedVault
    |                                              |
    |  1. Takes flash loan                         |
    |  2. Converts underlying -> MYT               |
    |                                              |
    |--- vaultDepositYieldTokens(amount) --------->|
    |                                              |-- alchemist.deposit(amount, self, positionId)
    |<-- returns sharesAdded ----------------------|
    |                                              |
    |--- vaultMintDebtTokens(amount, recipient) -->|
    |                                              |-- alchemist.mint(positionId, amount, recipient)
    |<--------------------------------------------|
    |                                              |
    |  3. Swaps debt -> underlying                 |
    |  4. Repays flash loan                        |
```

### Deleverage Callback Sequence

```
V3Leverager                                  LeveragedVault
    |                                              |
    |  1. Takes flash loan                         |
    |  2. Converts underlying -> MYT               |
    |                                              |
    |--- vaultRepayWithYieldTokens(amount) ------->|
    |                                              |-- alchemist.repay(positionId, amount)
    |<-- returns amountRepaid --------------------|
    |                                              |
    |--- vaultWithdrawYieldTokens(amount, self) -->|
    |                                              |-- alchemist.withdraw(amount, self, positionId)
    |<-- returns actualWithdrawn -----------------|
    |                                              |
    |  3. Converts freed MYT -> underlying         |
    |  4. Repays flash loan                        |
    |  5. Surplus -> user                          |
```

### Callback Functions

```solidity
interface ILeveragedVaultCallback {
    /// @notice Deposit yield tokens to vault's AlchemistV3 position
    /// @dev Creates position on first call (recipientId = 0)
    function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);

    /// @notice Mint debt tokens from vault's AlchemistV3 position
    function vaultMintDebtTokens(uint256 amount, address recipient) external;

    /// @notice Withdraw yield tokens from vault's AlchemistV3 position
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);

    /// @notice Repay debt using yield tokens (MYT) via AlchemistV3.repay()
    /// @dev Cannot be called in the same block as vaultMintDebtTokens (CannotRepayOnMintBlock).
    function vaultRepayWithYieldTokens(uint256 amount) external returns (uint256 amountRepaid);

    /// @notice Get vault's position ID
    function getVaultPositionId() external view returns (uint256 positionId);
}
```

All callbacks are protected by the `onlyLeverager` modifier -- only the vault's configured leverager can call them.

### Why Callbacks?

1. **Position ownership**: Only the vault owns its position NFT. The leverager cannot directly deposit/mint/withdraw/repay.
2. **Security**: The vault validates each callback operation internally.
3. **Separation of concerns**: The leverager handles orchestration (flash loans, swaps), the vault handles position management.
4. **Reusability**: One leverager works with many vaults without needing position access.

---

## Adapter System

The system uses three adapter interfaces to abstract external protocol interactions. This makes it possible to support different token pairs, flash loan providers, and DEX routes without changing core contracts.

### ITokenConverter

Converts between underlying tokens and yield tokens.

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

**Current implementation:** `MYTConverter` (90 LOC)
- `toYield`: WETH -> VaultV2.deposit() -> MYT shares
- `toUnderlying`: MYT shares -> VaultV2.redeem() -> WETH
- Fully deterministic -- no DEX interaction, no external market slippage. VaultV2 deposit/redeem are ERC4626 accounting operations.

The leverager validates that `converter.yieldToken()` and `converter.underlyingToken()` match the vault's tokens before every operation.

### IFlashLoanAdapter

Abstracts flash loan providers behind a unified interface.

```solidity
interface IFlashLoanAdapter {
    function flashLoan(address token, uint256 amount, address recipient, bytes calldata data) external;
    function getFlashLoanFee(address token, uint256 amount) external view returns (uint256 fee);
    function isTokenSupported(address token) external view returns (bool supported);
    function maxFlashLoan(address token) external view returns (uint256 maxAmount);
    function getProvider() external view returns (address provider);
}
```

**Current implementations:**

| Adapter | Provider | Fee | Notes |
|---------|----------|-----|-------|
| `BalancerFlashLoanAdapter` | Balancer V2 Vault | 0% | Recommended for most operations |
| `AaveV3FlashLoanAdapter` | Aave V3 Pool | 0.05% (5 bps) | Larger liquidity pool |
| `EulerFlashLoanAdapter` | Euler DTokens | 0% | Token-specific DToken mapping |

All adapters share:
- Reentrancy protection (`nonReentrant`)
- Pausability (`pause()` / `unpause()`)
- Emergency withdrawal (`emergencyWithdraw()`)
- Context validation on callbacks (prevents spoofed callbacks)
- Temporary context storage cleared after each operation

### ISwapper

Swaps between debt tokens and underlying tokens. Used only during leverage (not deleverage -- see below).

```solidity
interface ISwapper {
    function swapDebtToUnderlying(uint256 debtAmount, uint256 minUnderlyingOut, address recipient, bytes calldata swapData)
        external returns (uint256 underlyingReceived);
    function swapUnderlyingToDebt(uint256 underlyingAmount, uint256 minDebtOut, address recipient, bytes calldata swapData)
        external returns (uint256 debtReceived);
    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external view returns (uint256 expectedUnderlying, uint256 minimumOutput);
    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external view returns (uint256 expectedDebt, uint256 minimumOutput);
    function getDebtToUnderlyingRate() external view returns (uint256 rate);
    function getUnderlyingToDebtRate() external view returns (uint256 rate);
    function isSupportedPair(address tokenA, address tokenB) external view returns (bool supported);
}
```

**Current implementation:** `CurveSwapper` (288 LOC)
- Swaps between alETH and WETH via Curve's alETH/ETH pool
- Supports both ETH-native and ERC20 pool variants
- Configurable pool indices for different Curve pool layouts

### Registry Approval

The V3Leverager maintains an approval registry. Only the leverager owner can approve/revoke adapters:

```solidity
leverager.setConverterApproval(address(converter), true);
leverager.setFlashLoanAdapterApproval(address(balancerAdapter), true);
leverager.setSwapperApproval(address(curveSwapper), true);

// Or batch approve all at once
leverager.batchApprove(converters, flashLoanAdapters, swappers);
```

Every leverage/deleverage operation validates that adapters are approved before proceeding.

---

## Leverage Flow (Step by Step)

Entry points: `vault.leverage()`, `vault.leverageAtomic()`, or `vault.depositAndLeverageAtomic()`.

Access control: `leverage()` and `leverageAtomic()` are restricted to whitelisted addresses via `onlyWhitelistedLeverager`. `depositAndLeverageAtomic()` is exempt -- any user can deposit and leverage their own funds.

### 1. Vault prepares the operation

```
vault._executeLeverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin)
```

- Syncs Alchemist position via `poke()` to reflect accrued yield
- Validates pool has enough underlying balance (`clampedDeposit <= poolBalance`)
- Enforces minimum slippage floor on `debtTradeMin` via `_enforceMinimumSlippage()`
- Converts `clampedDeposit` of underlying -> MYT via converter
- Validates `mintAmount` does not exceed available + new borrow capacity
- Approves the leverager to pull MYT and mint debt
- Calls `leverager.leverage(params)`

### 2. Leverager orchestrates the flash loan

```
V3Leverager.leverage(LeverageParams params)
```

- Validates `msg.sender == params.vault` (only vaults can call)
- Validates all adapters are approved in the registry
- Validates converter tokens match vault's yield/underlying tokens
- Pulls the vault's MYT deposit
- Stores operation context in EIP-1153 transient storage
- Sets state to `FlashLoanState.Leverage`
- If `flashLoanAmount > 0`: calls `flashLoanAdapter.flashLoan()`
- If `flashLoanAmount == 0`: calls `_executeLeverageLogic()` directly

### 3. Core leverage logic executes

Whether called from the flash loan callback or directly:

1. Convert flash-loaned underlying -> MYT via converter (if flash loan > 0)
2. Combine with vault's MYT deposit
3. Call `vault.vaultDepositYieldTokens(totalMYT)` -> vault deposits to AlchemistV3
4. If `mintAmount > 0`:
   - Call `vault.vaultMintDebtTokens(mintAmount, self)` -> vault mints alETH
   - Swap alETH -> WETH via swapper
   - Repay flash loan from swap proceeds
   - Send surplus WETH to vault pool
5. If `mintAmount == 0`: deposit-only mode -- collateral is deposited with no debt (graceful degradation when Alchemist deposit capacity is limited)

### 4. Share minting

Shares are minted to the user during `depositUnderlying()`, **not during leverage**. The leverage operation increases the value of existing shares by growing the net position (collateral - debt). All share holders benefit proportionally from the leveraged yield.

---

## Deleverage Flow (Repay-Based)

When a user calls `vault.withdrawUnderlying()` and deleveraging is needed (Path 3).

The deleverage path is **repay-based**: it uses `AlchemistV3.repay()` with yield tokens (MYT) to reduce debt, rather than swapping underlying to debt tokens and burning. This makes the entire deleverage path deterministic through VaultV2 deposit/redeem -- no DEX swap is needed during withdrawal.

### 1. Vault determines withdrawal path

Three paths exist based on available liquidity:

| Path | Condition | Action |
|------|-----------|--------|
| **Path 1** | Pool balance >= withdrawal amount | Direct transfer from pool, no Alchemist interaction |
| **Path 2** | Pool + free Alchemist collateral sufficient | Withdraw MYT from Alchemist, convert to underlying |
| **Path 3** | Must deleverage (repay debt to free collateral) | Full flash loan deleverage cycle |

### 2. Path 3: Repay-based deleverage

```
vault.withdrawUnderlying(shares, flashLoanAmount, repayAmount, minUnderlyingOut, deadline)
```

- Burns shares **before** any external calls (CEI pattern)
- Transfers pool balance portion directly to the user (if any)
- Calls `leverager.deleverageRepay(params)` for the remainder

### 3. Leverager orchestrates deleverage

```
V3Leverager.deleverageRepay(DeleverageRepayParams params)
```

- Validates `msg.sender == params.vault` (only vaults can call)
- Sets state to `FlashLoanState.DeleverageRepay`
- Takes flash loan of underlying tokens

In the flash loan callback:

1. **Convert** flash-loaned WETH -> MYT via converter (deterministic, VaultV2 deposit)
2. **Repay** debt with MYT: `vault.vaultRepayWithYieldTokens(repayAmount)` -> calls `alchemist.repay(positionId, repayAmount)`
3. **Withdraw** freed collateral (MYT): `vault.vaultWithdrawYieldTokens(withdrawAmount, self)`
4. **Convert** all MYT (withdrawn + any conversion surplus) -> WETH via converter (deterministic, VaultV2 redeem)
5. **Repay** flash loan from converted WETH
6. **Send** surplus WETH to user

### Why repay-based?

- **No DEX swap needed.** The entire path uses VaultV2 deposit/redeem for conversions, which are deterministic ERC4626 operations. No Curve/Uniswap swap means no swap slippage risk during withdrawal.
- **Simpler parameter calculation.** The vault can compute exact amounts upfront since there is no market-dependent swap step.
- **AlchemistV3 constraint:** `repay()` cannot be called in the same block as `mint()` (CannotRepayOnMintBlock). The vault enforces this separation.

---

## Flash Loan Amount Calculation

The vault computes optimal flash loan amounts in `_calculateFlashLoanAmount()` based on slippage tolerances and the Alchemist's collateralization ratio.

### Formula

```
debtTradeLoss = 1 - debtSlippageBasisPoints / 10000
totalTradeLoss = debtTradeLoss * (1 - underlyingSlippageBasisPoints / 10000)

flashLoanAmount = (totalTradeLoss * depositAmount
                   + collateralizationRatio * debtTradeLoss * borrowCapacity)
                  / (collateralizationRatio - totalTradeLoss)
```

### Intuition

The flash loan amount is the largest loan the vault can take out and fully repay from the minted debt, accounting for:

1. **Underlying slippage**: Loss converting WETH -> MYT (typically ~0% via VaultV2, but configured for safety)
2. **Debt slippage**: Loss swapping alETH -> WETH (e.g., 2-4% via Curve, includes peg deviation)
3. **Collateralization ratio**: Required overcollateralization (e.g., 111%)
4. **Existing borrow capacity**: Pre-existing free collateral can absorb more flash loan

The flash loan fee is NOT pre-added to the amount. The leverager handles fee repayment from the debt swap output during execution.

### Capacity Clamping

If the total deposit (user amount + flash loan) would exceed the Alchemist's deposit capacity, the flash loan is clamped:

```solidity
uint256 expectedYieldFromTotal = alchemist.convertUnderlyingTokensToYield(depositAmount + flashLoanAmount);
if (expectedYieldFromTotal > depositCapacity) {
    uint256 maxUnderlying = alchemist.convertYieldTokensToUnderlying(depositCapacity);
    flashLoanAmount = maxUnderlying > depositAmount ? maxUnderlying - depositAmount : 0;
}
```

When deposit capacity is smaller than the requested deposit itself (`depositCapacity <= expectedYieldFromDeposit`), the deposit is clamped to fit and `mintAmount` is set to zero. The leverager deposits the collateral without minting any debt -- a deposit-only mode that allows a future leverage call to mint debt once capacity opens up.

---

## Creating New Vault Types

The system is designed to support any Alchemist V3 deployment. To add a new vault type for a different underlying/yield/debt token triple:

### Step 1: Identify the Token Triple

| Token | Role | Example (ETH) | Example (USD) |
|-------|------|---------------|---------------|
| Underlying | User deposits | WETH | DAI |
| Yield | Alchemist collateral | MYT (VaultV2 shares of wstETH) | yvDAI |
| Debt | Alchemist mints | alETH | alUSD |

### Step 2: Implement a Token Converter

Create a contract implementing `ITokenConverter` for your underlying <-> yield pair.

```solidity
contract DAIToYvDAIConverter is ITokenConverter {
    function toYield(uint256 amount, address recipient, uint256 minYieldOut)
        external returns (uint256) {
        // DAI -> yvDAI: deposit DAI into Yearn vault
        dai.approve(address(yearnVault), amount);
        uint256 shares = yearnVault.deposit(amount, recipient);
        require(shares >= minYieldOut, "slippage");
        return shares;
    }

    function toUnderlying(uint256 amount, address recipient, uint256 minUnderlyingOut)
        external returns (uint256) {
        // yvDAI -> DAI: withdraw from Yearn vault
        uint256 assets = yearnVault.redeem(amount, recipient, address(this));
        require(assets >= minUnderlyingOut, "slippage");
        return assets;
    }

    function yieldToken() external view returns (address) { return address(yvDAI); }
    function underlyingToken() external view returns (address) { return address(dai); }
    function previewToYield(uint256 amount) external view returns (uint256) {
        return yearnVault.previewDeposit(amount);
    }
    function previewToUnderlying(uint256 amount) external view returns (uint256) {
        return yearnVault.previewRedeem(amount);
    }
}
```

### Step 3: Implement a Swapper

Create a contract implementing `ISwapper` for your underlying <-> debt pair.

```solidity
contract AlUSDSwapper is ISwapper {
    function swapDebtToUnderlying(uint256 debtAmount, uint256 minOut, address recipient, bytes calldata)
        external returns (uint256) {
        // alUSD -> DAI via Curve alUSD pool
        return curvePool.exchange(alUSDIndex, daiIndex, debtAmount, minOut, recipient);
    }

    function swapUnderlyingToDebt(uint256 underlyingAmount, uint256 minOut, address recipient, bytes calldata)
        external returns (uint256) {
        // DAI -> alUSD via Curve alUSD pool
        return curvePool.exchange(daiIndex, alUSDIndex, underlyingAmount, minOut, recipient);
    }
    // ... preview functions, rate getters, etc.
}
```

The swap route depends on available DEX liquidity for your debt token. Options include Curve, Uniswap V3, or aggregators.

### Step 4: Choose a Flash Loan Adapter

Reuse an existing adapter if the underlying token has liquidity:
- `BalancerFlashLoanAdapter` -- 0% fee, if Balancer has liquidity for the token
- `AaveV3FlashLoanAdapter` -- 0.05% fee, very deep liquidity
- `EulerFlashLoanAdapter` -- 0% fee, token-specific

Or implement `IFlashLoanAdapter` for a new provider.

### Step 5: Register and Deploy

```solidity
// 1. Approve new adapters on the shared leverager
leverager.setConverterApproval(address(daiToYvDaiConverter), true);
leverager.setSwapperApproval(address(alUsdSwapper), true);
// Flash loan adapter may already be approved if reusing Balancer/Aave

// 2. Create vault via factory
address vault = factory.createVault(
    address(yvDAI),                  // yield token
    address(DAI),                    // underlying token
    address(alchemistV3_USD),        // AlchemistV3 for alUSD
    address(leverager),              // same shared leverager
    50,                              // 0.5% underlying slippage default
    200,                             // 2% debt slippage default
    address(daiToYvDaiConverter),    // new converter
    address(balancerAdapter),        // existing flash loan adapter
    address(alUsdSwapper),           // new swapper
    address(WETH)                    // WETH contract address
);

// 3. Whitelist keepers for leverage operations
LeveragedVault(vault).setLeverageWhitelist(keeper, true);
```

`createVault` is restricted to the factory owner. The WETH parameter is always the WETH contract address regardless of the vault's underlying token -- it is used for the `depositUnderlying()` payable function's ETH wrapping logic.

### Step 6: Verify

Before using the vault, verify:

- `converter.yieldToken()` matches the vault's yield token
- `converter.underlyingToken()` matches the vault's underlying token
- The Alchemist supports the yield token as collateral
- The flash loan adapter has liquidity for the underlying token (`isTokenSupported()`)
- The swapper handles the debt <-> underlying pair (`isSupportedPair()`)
- Slippage parameters are appropriate for the token pair's typical swap spreads

### Limitations

- Each vault is bound to one `(yieldToken, alchemist)` pair (enforced by factory)
- Adapters (converter, flash loan, swapper) are immutable per vault after initialization
- The `totalAssets()` oracle depends on `convertYieldTokensToUnderlying()` -- the yield token's price feed must be manipulation-resistant (Lido's `stEthPerToken` is safe; AMM spot prices are NOT)

---

## Initialization Parameters

### LeveragedVault (deployed via factory clone + initialize)

```solidity
vault.initialize(
    address yieldToken_,                    // Yield token (e.g., MYT / VaultV2 shares)
    address underlyingTokenAddress,         // Underlying token (e.g., WETH)
    address _alchemist,                     // AlchemistV3 contract
    address _leverager,                     // V3Leverager contract
    uint32 _underlyingSlippageBasisPoints,  // Default slippage (100 = 1%)
    uint32 _debtSlippageBasisPoints,        // Default slippage (400 = 4%)
    address _converter,                     // ITokenConverter (immutable after init)
    address _flashLoanAdapter,              // IFlashLoanAdapter (immutable after init)
    address _swapper,                       // ISwapper (immutable after init)
    address _weth,                          // WETH contract
    address initialOwner                    // Vault owner (set by factory to msg.sender)
)
```

The factory validates all addresses are non-zero and have deployed bytecode, validates converter token consistency (yield/underlying must match), and checks slippage < 10,000 bps.

### V3Leverager

```solidity
V3Leverager(address _owner)  // Owner for adapter registry management
```

---

## Related Tests

**363 non-fork tests** across 19 test contracts, using real AlchemistV3 (no mocks).

| Test File | Description |
|-----------|-------------|
| `IntegrationAndInvariant.t.sol` | Full deposit -> leverage -> withdraw cycle, deposit+leverage atomic, whitelist, share value invariants |
| `V3LeveragerModular.t.sol` | V3Leverager unit tests: registry, leverage, deleverage, state machine |
| `AdapterUnit.t.sol` | WstETHAdapter, MYTConverter, AaveV3FlashLoan adapter units |
| `CurveSwapperUnit.t.sol` | CurveSwapper isolated tests |
| `DeleverageUnit.t.sol` | Deleverage path coverage |
| `LeverageErrorPaths.t.sol` | Leverage error paths + parameter consistency |
| `SecurityTests.t.sol` | Callback spoofing, slippage enforcement, reentrancy |
| `AuditCoverage.t.sol` | Regression tests for all audit findings (S-01 through S-06) |
| `FuzzTests.t.sol` | Fuzz tests for share math + flash loan bounds |
| `VaultPositionInvariant.t.sol` | Position NFT + share value invariants |
| `LeveragedVaultFactory.t.sol` | Factory input validation, clone deployment, ownership |
| `LeveragedVaultPause.t.sol` | Pause blocks deposits/leverage, withdrawals remain available |
| `LocalAlchemistV3.t.sol` | AlchemistV3 stack integration (local, no fork) |
| `RepayDeleverage.t.sol` | Repay-based deleverage paths |
| `MYTConverter.t.sol` | MYTConverter configuration and conversion tests |
| `UnitMismatchTests.t.sol` | Unit conversion edge cases |

### Test Infrastructure

Tests use a real AlchemistV3 stack deployed locally (no fork required). The test base hierarchy:

- **`LocalAlchemistV3Base.t.sol`**: Deploys a real AlchemistV3 with underlying, debt token, MYT vault, and position NFT.
- **`LogrisTestBase.t.sol`**: Extends with the full Logris stack (leverager, MYTConverter, flash loan adapter, swapper, and a LeveragedVault clone).

```bash
# Run all non-fork tests
forge test --no-match-path "test/*{Fork,EdgeCases}*"

# Run integration tests
forge test --match-contract FullIntegrationTest -vv

# Run leverager unit tests
forge test --match-contract V3LeveragerModularTest -vv
```

### Fork Tests (require RPC endpoint)

| Test File | Description |
|-----------|-------------|
| `IntegrationFork.t.sol` | Full integration on mainnet fork |
| `FlashLoanAdapterFork.t.sol` | Real Balancer/Aave/Euler flash loans |
| `CurveSwapperFork.t.sol` | Real Curve pool swaps |
| `EdgeCases.t.sol` | Flash loan adapter edge cases on mainnet fork |

```bash
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
forge test --match-path "test/*Fork*" -vv
```
