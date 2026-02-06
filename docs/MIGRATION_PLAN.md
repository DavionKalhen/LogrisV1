# LeveragedVault Migration Plan: AlchemistV2 → AlchemistV3

## Overview

This document plans the migration of LeveragedVault from AlchemistV2 to AlchemistV3, preserving the original interface and behavior while adapting to V3's NFT-based position model.

---

## 1. API Mapping: AlchemistV2 → AlchemistV3

### Position/Account Queries

| AlchemistV2 | AlchemistV3 | Notes |
|-------------|-------------|-------|
| `positions(owner, yieldToken) → (shares, lastAccruedWeight)` | `getCDP(tokenId) → (collateral, debt, earmarked)` | V3 uses tokenId, returns collateral directly (not shares) |
| `accounts(owner) → (debt, depositedTokens[])` | `getCDP(tokenId)` | Combined into getCDP |
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
User deposits WETH → Alchemist wraps to yYieldToken → Credits shares to user
```

**V3**: Deposits YIELD tokens directly (e.g., wstETH)
```
User deposits wstETH → Alchemist credits collateral to position
```

**Implication**: The leverage flow must convert WETH flash loans to wstETH BEFORE depositing to Alchemist.

---

## 3. Functions to Implement in LeveragedVault

### 3.1 View Functions (Port from Old Leverager)

```solidity
// Get deposited balance (collateral) for the vault's position
function getVaultDepositedBalance() external view returns (uint256);

// Get debt balance for the vault's position
function getVaultDebtBalance() external view returns (int256);

// Get redeemable balance (collateral - debt value)
function getVaultRedeemableBalance() public view returns (uint256);

// Get remaining deposit capacity in Alchemist
function getDepositCapacity() public view returns (uint256);

// Get remaining borrow capacity for the vault's position
function getBorrowCapacity() public view returns (uint256);

// Get withdrawable shares without deleveraging
function getFreeWithdrawCapacity() public view returns (uint256);

// Get total withdrawable shares (may require deleveraging)
function getTotalWithdrawCapacity() public view returns (uint256);
```

### 3.2 Parameter Calculation Functions (CRITICAL - Port from Old Leverager)

```solidity
// Calculate all leverage parameters given deposit amount and slippage tolerances
function getLeverageParameters(
    uint256 depositAmount,
    uint32 underlyingSlippageBasisPoints,
    uint32 debtSlippageBasisPoints
) external view returns (
    uint256 clampedDeposit,      // Actual deposit (clamped to capacity)
    uint256 flashLoanAmount,     // Amount to flash loan
    uint256 underlyingDepositMin,// Min yield tokens to receive from deposit
    uint256 mintAmount,          // Amount of debt to mint
    uint256 debtTradeMin         // Min underlying from debt swap
);

// Calculate all withdraw parameters
function getWithdrawUnderlyingParameters(
    uint256 shares,
    uint32 underlyingSlippageBasisPoints,
    uint32 debtSlippageBasisPoints
) external view returns (
    uint256 flashLoanAmount,     // Amount to flash loan for deleveraging
    uint256 burnAmount,          // Amount of debt to burn
    uint256 minUnderlyingOut     // Min underlying to receive
);
```

### 3.3 Core Action Functions

```solidity
// Deposit underlying tokens (user-facing)
function depositUnderlying(uint256 amount) external returns (uint256 shares);
function depositUnderlying() external payable returns (uint256 shares); // ETH variant

// Execute leverage with explicit parameters
function leverage(
    uint256 clampedDeposit,
    uint256 flashLoanAmount,
    uint256 underlyingDepositMin,
    uint256 mintAmount,
    uint256 debtTradeMin
) external;

// Execute leverage with computed parameters (atomic/convenience)
function leverageAtomic(
    uint256 depositAmount,
    uint32 underlyingSlippageBasisPoints,
    uint32 debtSlippageBasisPoints
) external;

// Withdraw with explicit parameters
function withdrawUnderlying(
    uint256 shares,
    uint256 flashLoanAmount,
    uint256 burnAmount,
    uint256 minUnderlyingOut
) external returns (uint256 underlyingAmount);

// Withdraw with computed parameters (atomic/convenience)
function withdrawUnderlyingAtomic(
    uint256 shares,
    uint32 underlyingSlippageBasisPoints,
    uint32 debtSlippageBasisPoints
) external returns (uint256 underlyingAmount);
```

---

## 4. Flash Loan Amount Calculation

### Original Formula (from V2 Leverager)

The flash loan calculation accounts for:
1. **Underlying slippage**: Loss when converting WETH → wstETH
2. **Debt slippage**: Loss when swapping alETH → WETH (includes peg deviation)
3. **Collateralization ratio**: Required collateral/debt ratio (e.g., 111%)
4. **Existing borrow capacity**: Can leverage more if already have collateral

```solidity
/*
 * Derivation:
 * deposit amount ETH                                              D
 * borrow X ETH (flash loan)
 * deposit D+X yield tokens
 * receive (D+X)*underlyingSlippage borrow capacity
 * borrow ((D+X)*underlyingSlippage)/CR + existingBorrowCapacity
 * trade borrowed alETH for debtSlippage*alETH WETH
 * repay X ETH
 *
 * For the math to work: repayAmount = flashLoanAmount
 *
 * debtTradeLoss = 1 - debtSlippageBasisPoints/10000
 * totalTradeLoss = debtTradeLoss * (1 - underlyingSlippageBasisPoints/10000)
 *
 * flashLoanAmount = ((totalTradeLoss * depositAmount)
 *                    + (collateralizationRatio * debtTradeLoss * borrowCapacity))
 *                   / (collateralizationRatio - totalTradeLoss)
 */
function _calculateFlashLoanAmount(
    uint256 depositAmount,
    uint32 underlyingSlippageBasisPoints,
    uint32 debtSlippageBasisPoints,
    uint256 borrowCapacity,
    uint256 minimumCollateralization
) internal pure returns (uint256 flashLoanAmount) {
    uint256 debtTradeLoss = _basisPointAdjustment(1 ether, debtSlippageBasisPoints);
    uint256 totalTradeLoss = _basisPointAdjustment(debtTradeLoss, underlyingSlippageBasisPoints);

    flashLoanAmount = ((totalTradeLoss * depositAmount)
                       + (minimumCollateralization * debtTradeLoss * borrowCapacity / 1e18))
                       / (minimumCollateralization - totalTradeLoss);
}

function _basisPointAdjustment(uint256 amount, uint32 slippageBasisPoints) internal pure returns (uint256) {
    return amount * (10000 - slippageBasisPoints) / 10000;
}
```

### V3 Adaptation

In V3, we can use `getMaxBorrowable(tokenId)` instead of calculating borrow capacity manually. However, we need to account for:

1. **Current position state**: Query via `getCDP(vaultPositionId)`
2. **Future position state**: After depositing `depositAmount + flashLoanAmount`
3. **Conversion rates**: Use `convertYieldTokensToUnderlying()` and `normalizeDebtTokensToUnderlying()`

---

## 5. Leverage Flow (V3 Adapted)

```
1. User calls depositUnderlying(amount)
   → User's underlying tokens transferred to vault
   → Vault mints shares to user

2. Operator calls leverage(params) or leverageAtomic(amount, slippage)
   → Vault calculates or validates parameters
   → Vault approves leverager
   → Leverager executes:
      a. Take flash loan (WETH)
      b. Convert WETH → stETH → wstETH (Lido)
      c. Call vault.vaultDepositYieldTokens(wstETH amount)
         → Vault deposits to Alchemist, creates/updates position
      d. Call vault.vaultMintDebtTokens(alETH amount)
         → Vault mints alETH from position
      e. Swap alETH → WETH (Curve)
      f. Repay flash loan
      g. Return surplus to vault
```

---

## 6. Deleverage Flow (V3 Adapted)

```
1. User calls withdrawUnderlying(shares, params) or withdrawUnderlyingAtomic(shares, slippage)
   → If pool has enough unleveraged funds: simple withdrawal
   → If needs deleveraging:
      a. Take flash loan (WETH)
      b. Swap WETH → alETH (Curve)
      c. Call vault.vaultBurnDebtTokens(alETH amount)
         → Vault burns debt, freeing collateral
      d. Call vault.vaultWithdrawYieldTokens(wstETH amount)
         → Vault withdraws from Alchemist
      e. Convert wstETH → stETH → ETH → WETH (or direct sell)
      f. Repay flash loan
      g. Send underlying to user
   → Vault burns user's shares
```

---

## 7. Interface Contracts Needed

### ILeveragedVault.sol (Updated)

```solidity
interface ILeveragedVault is IERC4626 {
    // Events
    event DepositUnderlying(address indexed sender, address indexed underlyingToken, uint256 amount);
    event WithdrawUnderlying(address indexed sender, address indexed underlyingToken, uint256 shares);
    event Leverage(address indexed yieldToken, uint256 depositAmount, int256 debtAmount);

    // View functions
    function getYieldToken() external view returns (address);
    function getUnderlyingToken() external view returns (address);
    function getDepositPoolBalance() external view returns (uint256);
    function getVaultDepositedBalance() external view returns (uint256);
    function getVaultDebtBalance() external view returns (int256);
    function getVaultRedeemableBalance() external view returns (uint256);
    function getDepositCapacity() external view returns (uint256);
    function getBorrowCapacity() external view returns (uint256);
    function convertUnderlyingTokensToShares(uint256 amount) external view returns (uint256);
    function convertSharesToUnderlyingTokens(uint256 shares) external view returns (uint256);

    // Parameter calculation
    function getLeverageParameters(
        uint256 depositAmount,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external view returns (
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    );

    function getWithdrawUnderlyingParameters(
        uint256 shares,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external view returns (
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    );

    // User actions
    function depositUnderlying(uint256 amount) external returns (uint256 shares);
    function depositUnderlying() external payable returns (uint256 shares);

    // Leverage actions
    function leverage(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) external;

    function leverageAtomic(
        uint256 depositAmount,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external;

    // Withdraw actions
    function withdrawUnderlying(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    ) external returns (uint256 underlyingAmount);

    function withdrawUnderlyingAtomic(
        uint256 shares,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external returns (uint256 underlyingAmount);
}
```

---

## 8. Questions Requiring Clarification

Before implementing, the following need to be verified:

1. **V3 Deposit Flow**: Does AlchemistV3 `deposit()` expect yield tokens (wstETH) or does it have a `depositUnderlying()` equivalent?
   - **Answer**: V3 `deposit()` takes yield tokens directly. No `depositUnderlying` wrapper.

2. **Mint Allowance**: How does `approveMint` work when the vault owns the position?
   - **Answer**: Vault calls `alchemist.approveMint(vaultPositionId, leverager, amount)` before leverage.

3. **Flash Loan Fee**: Does Balancer V2 have flash loan fees?
   - **Answer**: No, Balancer V2 flash loans are fee-free.

4. **wstETH Conversion**: When we flash loan WETH, we need to convert to wstETH. What's the conversion path?
   - **Answer**: WETH → unwrap to ETH → stETH.submit() → wstETH.wrap()

5. **Position Creation**: Does V3 create a position automatically on first deposit?
   - **Answer**: Yes, passing `recipientId = 0` to `deposit()` creates a new position.

---

## 9. Implementation Order

1. **Phase 1**: Update ILeveragedVault interface with all required functions
2. **Phase 2**: Implement view functions (getDepositCapacity, getBorrowCapacity, etc.)
3. **Phase 3**: Implement `getLeverageParameters()` and `_calculateFlashLoanAmount()`
4. **Phase 4**: Implement `getWithdrawUnderlyingParameters()`
5. **Phase 5**: Update `leverage()` to use V3-style 5-parameter signature
6. **Phase 6**: Implement `leverageAtomic()` convenience function
7. **Phase 7**: Implement deleverage flow in `withdrawUnderlying()`
8. **Phase 8**: Implement `withdrawUnderlyingAtomic()` convenience function
9. **Phase 9**: Update tests to cover all scenarios

---

## 10. Files to Modify

| File | Changes |
|------|---------|
| `src/interfaces/ILeveragedVault.sol` | Add all view and action function signatures |
| `src/LeveragedVault.sol` | Implement all functions, integrate with AlchemistV3 |
| `src/leveragers/SimpleLeveragerWstETH.sol` | Update to work with new vault interface |
| `test/LeveragedVault.t.sol` | New comprehensive test suite |

---

## 11. Safety Considerations

1. **Slippage Protection**: All swap operations must have minimum output checks
2. **Reentrancy**: Use checks-effects-interactions pattern, consider ReentrancyGuard
3. **Flash Loan Validation**: Verify callback is from expected flash loan provider
4. **Position Ownership**: Only vault should be able to operate on vaultPositionId
5. **Sanity Checks**: Validate actual amounts match expected after each operation
