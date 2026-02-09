# Alchemix V3 Integration Guide

This document explains how Logris V1 integrates with Alchemix V3 to create leveraged yield positions. It covers the callback architecture, adapter system, and how to extend the system for new token pairs.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [AlchemistV3 Position Model](#alchemistv3-position-model)
3. [Callback Pattern](#callback-pattern)
4. [Adapter System](#adapter-system)
5. [Leverage Flow (Step by Step)](#leverage-flow-step-by-step)
6. [Deleverage Flow (Step by Step)](#deleverage-flow-step-by-step)
7. [Flash Loan Amount Calculation](#flash-loan-amount-calculation)
8. [Creating New Vault Types](#creating-new-vault-types)
9. [V2 vs V3 Differences](#v2-vs-v3-differences)
10. [Initialization Parameters](#initialization-parameters)
11. [Related Tests](#related-tests)

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
  |--- leverage() / withdrawUnderlying() --->  V3Leverager (shared)
  |                                               |
  |<-- callbacks (deposit/mint/withdraw/burn) ----+
  |                                               |
  |                                    +----------+-----------+
  |                                    |          |           |
  |                              Converter  FlashLoan    Swapper
  |                            (ITokenConv) (IFlashLoan) (ISwapper)
  |                                    |          |           |
  |                              WETH<->wstETH  Balancer  alETH<->WETH
  |                              (via Lido)     Aave V3   (via Curve)
  v                                             Euler
AlchemistV3
  |
  +-- Position NFT (ERC-721)
  +-- Collateral (yield tokens, e.g., wstETH)
  +-- Debt (debt tokens, e.g., alETH)
  +-- Earmarked collateral (committed to transmuter)
```

The system is designed so that:
- **One leverager serves all vaults.** V3Leverager is deployed once and shared.
- **Adapters are approved via registry.** The leverager owner approves converters, flash loan adapters, and swappers. No redeployment needed.
- **Each vault binds to one adapter set.** At initialization, each vault is permanently linked to a specific converter, flash loan adapter, and swapper.
- **All depositors share one position.** Each vault holds a single AlchemistV3 position NFT. Share value tracks the net position value.

---

## AlchemistV3 Position Model

Alchemix V3 uses **NFT-based positions** (ERC-721). Each position has:

| Field | Description |
|-------|-------------|
| `collateral` | Yield tokens deposited (e.g., wstETH amount) |
| `debt` | Debt tokens owed (e.g., alETH amount) |
| `earmarked` | Collateral committed to the Alchemist transmuter |

Query a position:
```solidity
(uint256 collateral, uint256 debt, uint256 earmarked) = alchemist.getCDP(positionId);
```

Key Alchemist V3 functions used by the vault:

| Function | Purpose |
|----------|---------|
| `deposit(amount, recipient, recipientId)` | Deposit yield tokens. Pass `recipientId = 0` to create a new position. |
| `withdraw(amount, recipient, tokenId)` | Withdraw yield tokens from a position. |
| `mintFrom(tokenId, amount, recipient)` | Mint debt tokens against collateral. Requires `approveMint()`. |
| `burn(amount, recipientId)` | Burn debt tokens to reduce position debt. |
| `approveMint(tokenId, spender, amount)` | Authorize an address to mint from a position. |
| `getCDP(tokenId)` | Query position state (collateral, debt, earmarked). |
| `getMaxBorrowable(tokenId)` | Get remaining borrow capacity. |
| `convertYieldTokensToUnderlying(amount)` | Convert yield token amount to underlying value. |
| `convertUnderlyingTokensToYield(amount)` | Convert underlying amount to yield token equivalent. |
| `normalizeDebtTokensToUnderlying(amount)` | Convert debt token amount to underlying value. |
| `minimumCollateralization()` | Get required collateral ratio (e.g., 1.11e18 = 111%). |
| `depositCap()` / `getTotalDeposited()` | Global deposit limits. |

---

## Callback Pattern

The vault implements `ILeveragedVaultCallback` to let the leverager interact with its AlchemistV3 position. This is the core architectural pattern: **the leverager never directly touches the Alchemist**. Instead, it calls back into the vault, which performs the privileged operation on its own position.

```
V3Leverager                                  LeveragedVault
    |                                              |
    |  1. Takes flash loan                         |
    |  2. Converts underlying -> yield             |
    |                                              |
    |--- vaultDepositYieldTokens(amount) --------->|
    |                                              |-- alchemist.deposit(amount, self, positionId)
    |<-- returns sharesAdded ----------------------|
    |                                              |
    |--- vaultMintDebtTokens(amount, recipient) -->|
    |                                              |-- alchemist.approveMint(positionId, leverager, amount)
    |                                              |-- alchemist.mintFrom(positionId, amount, recipient)
    |<--------------------------------------------|
    |                                              |
    |  3. Swaps debt -> underlying                 |
    |  4. Repays flash loan                        |
```

### Callback Functions

```solidity
interface ILeveragedVaultCallback {
    /// @notice Deposit yield tokens to vault's AlchemistV3 position
    /// @dev Creates position on first call (recipientId = 0)
    function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);

    /// @notice Mint debt tokens from vault's AlchemistV3 position
    /// @dev Vault calls approveMint() then leverager calls mintFrom()
    function vaultMintDebtTokens(uint256 amount, address recipient) external;

    /// @notice Withdraw yield tokens from vault's AlchemistV3 position
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);

    /// @notice Burn debt tokens against vault's AlchemistV3 position
    function vaultBurnDebtTokens(uint256 amount) external;

    /// @notice Get vault's position ID
    function getVaultPositionId() external view returns (uint256 positionId);
}
```

All callbacks are protected by the `onlyLeverager` modifier -- only the vault's configured leverager can call them.

### Why Callbacks?

1. **Position ownership**: Only the vault owns its position NFT. The leverager cannot directly deposit/mint/withdraw/burn.
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

**Current implementation:** `WETHToWstETHConverter` (205 LOC)
- `toYield`: WETH -> unwrap to ETH -> stETH via `Lido.submit()` -> wstETH via `wstETH.wrap()`
- `toUnderlying`: wstETH -> stETH via `wstETH.unwrap()` -> ETH via Curve stETH/ETH pool -> WETH via `WETH.deposit()`

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

Swaps between debt tokens and underlying tokens.

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

**Current implementation:** `CurveSwapper` (283 LOC)
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

Every leverage/deleverage operation validates that all three adapters are approved before proceeding:
```
if (!isApprovedConverter(params.converter)) revert UnapprovedConverter();
if (!isApprovedFlashLoanAdapter(params.flashLoanAdapter)) revert UnapprovedFlashLoanAdapter();
if (!isApprovedSwapper(params.swapper)) revert UnapprovedSwapper();
```

---

## Leverage Flow (Step by Step)

When a user calls `vault.leverage()` or `vault.leverageAtomic()`:

### 1. Vault prepares the operation

```
vault.leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin)
```

- Validates pool has enough underlying balance (`clampedDeposit <= poolBalance`)
- Enforces minimum slippage floor on `debtTradeMin` via `_enforceMinimumSlippage()`
- Sets `operationInProgress = true` to prevent concurrent operations
- Transfers `clampedDeposit` of underlying to the converter
- Converts underlying -> yield tokens via converter
- Deposits yield tokens to the vault contract (for leverager to use in callback)
- Calls `leverager.leverage(params)` with the vault's adapter addresses

### 2. Leverager orchestrates the flash loan

```
V3Leverager.leverage(LeverageParams params)
```

- Validates all three adapters are approved in the registry
- Validates converter tokens match vault's yield/underlying tokens
- Sets state to `FlashLoanState.Leverage`
- Stores operation context in `_context`
- Calls `flashLoanAdapter.flashLoan(underlyingToken, flashLoanAmount, self, data)`

### 3. Flash loan callback executes

```
V3Leverager.onFlashLoanReceived(token, amount, fee, data)
```

- Validates `msg.sender == flashLoanAdapter` and `initiator == address(this)`
- Validates state is `FlashLoanState.Leverage`
- Converts flash-loaned underlying -> yield tokens via converter
- Calls `vault.vaultDepositYieldTokens(yieldAmount)` -- vault deposits to AlchemistV3
- Calls `vault.vaultMintDebtTokens(mintAmount, self)` -- vault mints debt tokens
- Swaps debt tokens -> underlying via swapper
- Repays flash loan (principal + fee)
- Returns surplus underlying to caller

### 4. Share minting

Shares are minted to the user during `depositUnderlying()`, **not during leverage**. The leverage operation increases the value of existing shares by growing the net position (collateral - debt). All share holders benefit proportionally from the leveraged yield.

---

## Deleverage Flow (Step by Step)

When a user calls `vault.withdrawUnderlying()` and deleveraging is needed (Path 3):

### 1. Vault determines withdrawal path

Three paths exist based on available liquidity:

| Path | Condition | Action |
|------|-----------|--------|
| **Path 1** | Pool balance >= withdrawal amount | Direct transfer, no Alchemist interaction |
| **Path 2** | Pool + free Alchemist collateral sufficient, no debt to burn | Withdraw from Alchemist, convert yield -> underlying |
| **Path 3** | Must deleverage (burn debt to free collateral) | Full flash loan deleverage cycle |

### 2. Path 3: Full deleverage

```
vault.withdrawUnderlying(shares, flashLoanAmount, burnAmount, minUnderlyingOut)
```

- Burns shares **before** any external calls (CEI pattern)
- Subtracts pool balance from the needed underlying amount
- Transfers pool balance portion directly to the user
- Calls `leverager.deleverage(params)` for the remainder

### 3. Leverager orchestrates deleverage

```
V3Leverager.deleverage(DeleverageParams params)
```

- Sets state to `FlashLoanState.Deleverage`
- Takes flash loan of underlying tokens
- In callback:
  1. Swaps underlying -> debt tokens via swapper
  2. Calls `vault.vaultBurnDebtTokens(burnAmount)` -- burns only `burnAmount`, surplus debt tokens go to user
  3. Calls `vault.vaultWithdrawYieldTokens(withdrawAmount, self)` -- withdraws freed collateral
  4. Converts yield -> underlying via converter
  5. Repays flash loan
  6. Sends remaining underlying to the user

---

## Flash Loan Amount Calculation

The vault computes optimal flash loan amounts based on slippage tolerances and the Alchemist's collateralization ratio.

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

1. **Underlying slippage**: Loss converting WETH -> wstETH (e.g., 1% via Lido)
2. **Debt slippage**: Loss swapping alETH -> WETH (e.g., 4% via Curve, includes peg deviation)
3. **Collateralization ratio**: Required overcollateralization (e.g., 111%)
4. **Existing borrow capacity**: Pre-existing free collateral can absorb more flash loan

The flash loan fee is NOT pre-added to the amount. The leverager handles fee repayment from the debt swap output during execution.

### Capacity Clamping

If the total deposit (user amount + flash loan) would exceed the Alchemist's deposit capacity, the vault clamps the amounts:

```solidity
if (expectedYieldFromTotal > depositCapacity) {
    // Reduce to fit within capacity
    flashLoanAmount = convertYieldTokensToUnderlying(depositCapacity - expectedYieldFromDeposit);
}
```

---

## Creating New Vault Types

The system is designed to support any Alchemist V3 deployment. To add a new vault type for a different underlying/yield/debt token triple:

### Step 1: Identify the Token Triple

| Token | Role | Example (ETH) | Example (USD) |
|-------|------|---------------|---------------|
| Underlying | User deposits | WETH | DAI |
| Yield | Alchemist collateral | wstETH | yvDAI |
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

// 2. Create vault via factory (onlyOwner)
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
    address(WETH)                    // WETH contract address (always WETH, used for ETH deposit wrapping)
);
```

Note: `createVault` is restricted to the factory owner (`onlyOwner`). The last parameter is always the WETH contract address regardless of the vault's underlying token -- it is used for the `depositUnderlying()` payable function's ETH wrapping logic.

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

## V2 vs V3 Differences

| Feature | Alchemix V2 | Alchemix V3 |
|---------|------------|------------|
| Position model | Account-based (keyed on address) | NFT-based (ERC-721 token IDs) |
| Position ID | `msg.sender` address | `uint256 tokenId` |
| Multiple positions | One per yield token per address | Unlimited per address |
| Deposit function | `depositUnderlying(yieldToken, amount, recipient, minOut)` -- Alchemist converts | `deposit(amount, recipient, recipientId)` -- caller provides yield tokens |
| Withdraw function | `withdrawUnderlyingFrom(owner, yieldToken, shares, recipient, minOut)` | `withdraw(amount, recipient, tokenId)` -- returns yield tokens |
| Mint authorization | `approveMint(spender, amount)` | `approveMint(tokenId, spender, amount)` |
| Mint function | `mintFrom(owner, amount, recipient)` | `mintFrom(tokenId, amount, recipient)` |
| Burn function | `burn(amount, recipient)` | `burn(amount, recipientId)` |
| Capacity query | `getYieldTokenParameters(yieldToken)` | `depositCap()` + `getTotalDeposited()` |
| Borrow capacity | Calculated from collateralization ratio | `getMaxBorrowable(tokenId)` |
| Collateral units | Shares (internal accounting) | Yield tokens directly |
| Conversion | `convertSharesToUnderlyingTokens(yieldToken, shares)` | `convertYieldTokensToUnderlying(amount)` |

**Key implication for Logris:** In V3, the leverage flow must convert WETH to wstETH **before** depositing to the Alchemist (V2 handled conversion internally). This is why the converter adapter exists.

---

## Initialization Parameters

### LeveragedVault (deployed via factory clone + initialize)

```solidity
vault.initialize(
    address yieldToken_,                    // Yield token (e.g., wstETH)
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

The factory validates all addresses are non-zero and have deployed bytecode, and checks slippage < 10,000 bps.

### V3Leverager

```solidity
V3Leverager(address _owner)  // Owner for adapter registry management
```

---

## Related Tests

| Test File | Description |
|-----------|-------------|
| `test/IntegrationAndInvariant.t.sol` | Full deposit -> leverage -> withdraw cycle, share value invariants |
| `test/V3LeveragerModular.t.sol` | V3Leverager unit tests with mocks: registry, leverage, deleverage |
| `test/V3LeveragerE2E.t.sol` | E2E tests on mainnet fork with real AlchemistV3 + Curve |
| `test/AdapterUnit.t.sol` | WstETHAdapter, WETHToWstETHConverter, AaveV3FlashLoan unit tests |
| `test/SecurityTests.t.sol` | Callback spoofing, slippage enforcement, reentrancy tests |
| `test/AuditCoverage.t.sol` | Regression tests for all audit findings (S-02 through S-06) |
| `test/DeleverageUnit.t.sol` | Deleverage path unit tests |
| `test/LeverageErrorPaths.t.sol` | Leverage error path coverage |
| `test/FuzzTests.t.sol` | Fuzz tests for share math + flash loan bounds |

Run integration tests:
```bash
forge test --match-contract FullIntegrationTest -vv
forge test --match-contract V3LeveragerModularTest -vv
```
