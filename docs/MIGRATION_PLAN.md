# LeveragedVault Migration Plan: AlchemistV2 -> AlchemistV3

> **Status: COMPLETED** (2026-02-07)
>
> This document is a historical record of the V2 -> V3 migration planning. The migration
> has been fully implemented and audited (two rounds). For current architecture documentation,
> see the [README](../README.md) and the [Alchemix V3 Integration Guide](alchemix-v3-integration.md).

---

## Overview

This document planned the migration of LeveragedVault from AlchemistV2 to AlchemistV3, preserving the original interface and behavior while adapting to V3's NFT-based position model.

**Outcome:** All planned changes were implemented successfully. The system now uses:
- `V3Leverager` (replaced `SimpleLeveragerWstETH`) as a modular, registry-based leverager
- NFT-based position management via `ILeveragedVaultCallback`
- EIP-1167 minimal proxy clones via `LeveragedVaultFactory`
- ERC-7201 namespaced storage for clone-safe storage layout
- Modular adapter system (`ITokenConverter`, `IFlashLoanAdapter`, `ISwapper`)
- Test suite split across 19 files (345 non-fork tests)

---

## 1. API Mapping: AlchemistV2 -> AlchemistV3

### Position/Account Queries

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `positions(owner, yieldToken) -> (shares, lastAccruedWeight)` | `getCDP(tokenId) -> (collateral, debt, earmarked)` | V3 uses tokenId, returns collateral directly (not shares) |
| `accounts(owner) -> (debt, depositedTokens[])` | `getCDP(tokenId)` | Combined into getCDP |
| `convertSharesToUnderlyingTokens(yieldToken, shares)` | `convertYieldTokensToUnderlying(amount)` | V3 has no shares concept, collateral IS yield tokens |
| N/A | `getMaxBorrowable(tokenId)` | **NEW in V3** - directly returns max borrowable |

### Deposit/Withdraw Actions

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `depositUnderlying(yieldToken, amount, recipient, minOut)` | `deposit(amount, recipient, recipientId)` | V3 deposits yield tokens directly (wstETH), NOT underlying (WETH) |
| `withdrawUnderlyingFrom(owner, yieldToken, shares, recipient, minOut)` | `withdraw(amount, recipient, tokenId)` | V3 returns yield tokens, not underlying |

### Mint/Burn Actions

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `approveMint(spender, amount)` | `approveMint(tokenId, spender, amount)` | V3 requires tokenId |
| `mintFrom(owner, amount, recipient)` | `mintFrom(tokenId, amount, recipient)` | V3 uses tokenId |
| `burn(amount, recipient)` | `burn(amount, recipientId)` | V3 uses tokenId |

### Capacity/Limits

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `getYieldTokenParameters(yieldToken).maximumExpectedValue` | `depositCap()` | Global deposit cap |
| `getYieldTokenParameters(yieldToken).expectedValue` | `getTotalDeposited()` | Current total deposits |
| Calculated from collateralization | `getMaxBorrowable(tokenId)` | V3 provides this directly |

### Conversion Functions

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `convertUnderlyingTokensToYield(yieldToken, amount)` | `convertUnderlyingTokensToYield(amount)` | No yieldToken param needed |
| `convertYieldTokensToUnderlying(yieldToken, amount)` | `convertYieldTokensToUnderlying(amount)` | No yieldToken param needed |
| `normalizeDebtTokensToUnderlying(underlyingToken, amount)` | `normalizeDebtTokensToUnderlying(amount)` | No underlyingToken param |
| `minimumCollateralization()` | `minimumCollateralization()` | Same |

---

## 2. Key Architectural Differences

### Position Model

**V2**: Address-based positions
- Each user address has one position per yield token
- Positions tracked by `(address, yieldToken)` tuple
- Shares represent user's portion of the vault

**V3**: NFT-based positions
- Each position is an ERC721 token with unique `tokenId`
- Users can have multiple positions
- Collateral is stored directly (not as shares)
- Vault owns a single shared position (`vaultPositionId`)

### Deposit Flow

**V2**: Deposits UNDERLYING tokens (e.g., WETH)
```
User deposits WETH -> Alchemist wraps to yYieldToken -> Credits shares to user
```

**V3**: Deposits YIELD tokens directly (e.g., wstETH)
```
User deposits wstETH -> Alchemist credits collateral to position
```

**Implication**: The leverage flow must convert WETH flash loans to wstETH BEFORE depositing to Alchemist. This is handled by the `ITokenConverter` adapter.

---

## 3. Implementation Outcome

All planned functions were implemented in `LeveragedVault.sol` (1,013 LOC):

### View Functions (implemented)
- `getVaultDepositedBalance()` -- queries `alchemist.getCDP(positionId)`
- `getVaultDebtBalance()` -- queries position debt
- `getVaultRedeemableBalance()` -- pool + (collateral - earmarked - debt), in underlying
- `getDepositCapacity()` -- `depositCap() - getTotalDeposited()`
- `getBorrowCapacity()` -- `getMaxBorrowable(positionId)`
- `getFreeWithdrawCapacity()` -- collateral withdrawable without deleveraging
- `getTotalWithdrawCapacity()` -- total withdrawable (may require deleveraging)

### Parameter Calculation (implemented)
- `getLeverageParameters()` -- computes flash loan amount, mint amount, slippage minimums
- `getWithdrawUnderlyingParameters()` -- computes deleverage params
- Both have overloads: one using vault default slippage, one with explicit slippage params

### Core Actions (implemented)
- `depositUnderlying(uint256)` / `depositUnderlying()` payable
- `leverage()` / `leverageAtomic()`
- `withdrawUnderlying()` / `withdrawUnderlyingAtomic()`

---

## 4. Flash Loan Amount Calculation (implemented)

The formula accounts for underlying slippage, debt slippage, collateralization ratio, and existing borrow capacity:

```
debtTradeLoss = 1 - debtSlippageBasisPoints / 10000
totalTradeLoss = debtTradeLoss * (1 - underlyingSlippageBasisPoints / 10000)

flashLoanAmount = (totalTradeLoss * depositAmount
                   + collateralizationRatio * debtTradeLoss * borrowCapacity)
                  / (collateralizationRatio - totalTradeLoss)
```

---

## 5. Files Changed (final state)

| Planned File | Actual Outcome |
|--------------|----------------|
| `src/interfaces/ILeveragedVault.sol` | Implemented with all view + action signatures |
| `src/LeveragedVault.sol` | 1,013 LOC, all functions implemented with ERC-7201 storage |
| `src/leveragers/SimpleLeveragerWstETH.sol` | **Replaced** by `src/leveragers/V3Leverager.sol` (463 LOC) |
| `test/LeveragedVault.t.sol` | **Split** across 19 test files (345 non-fork tests) |

### Additional files created during migration (not in original plan)

| File | Purpose |
|------|---------|
| `src/LeveragedVaultFactory.sol` | EIP-1167 clone factory (109 LOC) |
| `src/ERC4626Upgradeable.sol` | Custom ERC4626 with ERC-7201 storage (180 LOC) |
| `src/interfaces/ILeveragedVaultCallback.sol` | Callback interface for leverager -> vault |
| `src/interfaces/ILeveragerV3.sol` | Generic leverager interface + param structs |
| `src/interfaces/ITokenConverter.sol` | Converter interface |
| `src/interfaces/ISwapper.sol` | Swapper interface |
| `src/interfaces/flashloan/IFlashLoanAdapter.sol` | Flash loan adapter interface |
| `src/adapters/flashloan/BalancerFlashLoanAdapter.sol` | Balancer V2 flash loan adapter |
| `src/adapters/flashloan/AaveV3FlashLoanAdapter.sol` | Aave V3 flash loan adapter |
| `src/adapters/flashloan/EulerFlashLoanAdapter.sol` | Euler flash loan adapter |
| `src/adapters/CurveSwapper.sol` | Curve alETH/WETH swapper |
| `src/adapters/WstETHAdapter.sol` | AlchemistV3 token adapter for wstETH |
| `src/converters/WETHToWstETHConverter.sol` | WETH <-> wstETH converter |

---

## 6. Questions & Answers (all resolved)

1. **V3 Deposit Flow**: Does AlchemistV3 `deposit()` expect yield tokens?
   - **Answer**: Yes, V3 `deposit()` takes yield tokens directly. No `depositUnderlying` wrapper.

2. **Mint Allowance**: How does `approveMint` work when the vault owns the position?
   - **Answer**: Vault calls `alchemist.approveMint(vaultPositionId, leverager, amount)` before leverage.

3. **Flash Loan Fee**: Does Balancer V2 have flash loan fees?
   - **Answer**: No, Balancer V2 flash loans are fee-free.

4. **wstETH Conversion**: WETH -> wstETH conversion path?
   - **Answer**: WETH -> unwrap to ETH -> `stETH.submit()` -> `wstETH.wrap()`

5. **Position Creation**: Does V3 create a position automatically on first deposit?
   - **Answer**: Yes, passing `recipientId = 0` to `deposit()` creates a new position.

---

## 7. Safety Considerations (all addressed)

| Concern | Resolution |
|---------|------------|
| Slippage Protection | All swap operations have minimum output checks; `_enforceMinimumSlippage()` floor |
| Reentrancy | `ReentrancyGuardUpgradeable`, `noConcurrentOperation`, CEI pattern on all paths |
| Flash Loan Validation | State machine (Idle/Leverage/Deleverage), `initiator == address(this)` check |
| Position Ownership | `onlyLeverager` modifier on all callbacks, `_requireSinglePosition()` |
| Sanity Checks | Converter token consistency validated before every operation |
| Inflation Attack | `_decimalsOffset() = 3` (1000 virtual shares) |
| Emergency Recovery | `emergencySweepToken`, `emergencySweepETH`, `sweepUnknownPosition` |
| Audit | Two rounds completed (Feb 2026), all MEDIUM+ findings fixed |
