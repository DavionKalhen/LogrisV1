# Alchemix V3 Integration Guide

This document explains how we've adapted our flash loan-based leveraging system to work with Alchemix V3.

## Overview of Changes

Alchemix V3 introduces a major architectural change from V2:

- **Alchemix V2**: Used account-based positions where each user had a direct account position in the Alchemist contract
- **Alchemix V3**: Uses NFT-based positions where each position is represented by an ERC-721 token

Our system uses a callback pattern where the vault owns a single Alchemist V3 position, and leveragers interact with it through a callback interface.

## Key Components

1. **LeveragedVault**: ERC4626 vault that owns a single Alchemist V3 position
2. **ILeveragedVaultCallback**: Interface allowing leveragers to interact with the vault's position
3. **V3Leverager**: Generic leverager that orchestrates flash loans, swaps, and conversions
4. **Adapters**: `ITokenConverter`, `IFlashLoanAdapter`, `ISwapper`

## Architecture Pattern

```
User → LeveragedVault → Leverager → Flash Loan Provider
                    ↑         ↓
                    └─ Callback (deposit/mint/withdraw/burn)
```

The vault owns the Alchemist V3 position NFT. When leverage operations execute:
1. Leverager takes flash loan
2. Leverager calls vault callbacks to deposit yield tokens and mint debt
3. Leverager swaps debt tokens to repay flash loan
4. User receives proportional vault shares

## Using the System

### Initialization

```solidity
// Deploy the leverager and approve adapters
V3Leverager leverager = new V3Leverager(owner);
leverager.setConverterApproval(address(converter), true);
leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
leverager.setSwapperApproval(address(swapper), true);

// Deploy the vault with default adapters
LeveragedVault vault = new LeveragedVault(
    "Vault Name",
    "VTKN",
    YIELD_TOKEN,
    UNDERLYING_TOKEN,
    ALCHEMIST_V3_ADDRESS,
    address(leverager),
    100, // underlying slippage bps
    300, // debt slippage bps
    address(converter),
    address(flashLoanAdapter),
    address(swapper),
    WETH_ADDRESS
);
```

### Performing Leverage Operations

```solidity
// Deposit underlying tokens first
underlyingToken.approve(address(vault), DEPOSIT_AMOUNT);
uint256 shares = vault.depositUnderlying(DEPOSIT_AMOUNT);

// Execute leverage through the vault
vault.leverage(
    DEPOSIT_AMOUNT,      // clamped deposit amount
    FLASH_LOAN_AMOUNT,   // flash loan size
    UNDERLYING_MIN,      // min underlying after conversion
    MINT_AMOUNT,         // debt to mint
    DEBT_TRADE_MIN       // min from debt swap
);

// Withdraw with deleveraging if needed
vault.withdrawUnderlying(
    SHARES_TO_WITHDRAW,
    FLASH_LOAN_AMOUNT,
    BURN_AMOUNT,
    MIN_UNDERLYING_OUT
);
```

## V2 vs V3 Differences

| Feature | Alchemix V2 | Alchemix V3 |
|---------|------------|------------|
| Position model | Account-based | NFT-based (ERC-721) |
| Position ID | User address | Token ID |
| Delegation | Custom approvals | Standard ERC-721 approvals + custom minting approvals |
| Yield tokens | Custom integrations | Direct integration with yield tokens |

## Implementation Details

The vault maintains a single Alchemist V3 position for all users:

```solidity
uint256 public vaultPositionId; // The vault's position ID in Alchemist v3
```

The vault implements `ILeveragedVaultCallback` to allow the leverager to interact with this position:

```solidity
interface ILeveragedVaultCallback {
    function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);
    function vaultMintDebtTokens(uint256 amount, address recipient) external;
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);
    function vaultBurnDebtTokens(uint256 amount) external;
    function getVaultPositionId() external view returns (uint256 positionId);
}
```

Only the authorized leverager can call these callbacks (enforced by `onlyLeverager` modifier).

## Flash Loan Example

Here's how a flash loan leverage operation works with Alchemix V3:

1. User calls `vault.leverage()` with deposit and flash loan parameters
2. Leverager takes a flash loan from Balancer
3. Leverager converts underlying tokens to yield tokens
4. Leverager calls `vault.vaultDepositYieldTokens()` to deposit to the vault's position
5. Leverager calls `vault.vaultMintDebtTokens()` to mint debt against the position
6. Leverager swaps debt tokens for underlying tokens via Curve
7. Leverager repays flash loan
8. Vault mints shares to user based on leverage efficiency bonuses

## Testing

Tests are available in `test/LeveragedVaultTest.t.sol` that verify:
- Vault position creation and management
- Flash loan leveraging with Balancer integration
- Multi-user deposits and proportional share calculations
- Leverage efficiency bonuses and metrics
- Swap functionality with Curve integration

Additional tests are available in:
- `test/BasicAlchemistV3Integrator.t.sol` - Basic Alchemist V3 operations
- `test/AlchemistV3LeverageCalculator.t.sol` - Leverage calculation tests

Run all V3-related tests with:
```bash
forge test --match-path "test/*V3*.t.sol" -vvv
forge test --match-path "test/LeveragedVaultTest.t.sol" -vvv
```

## Constructor Parameters

### LeveragedVault

```solidity
LeveragedVault(
    string memory tokenName,              // Vault token name
    string memory tokenDescription,       // Vault token symbol
    address yieldToken,                   // Yield token (e.g., wstETH)
    address underlyingToken,              // Underlying token (e.g., WETH)
    address alchemistV3,                  // Alchemist V3 contract
    address leverager,                    // Leverager contract
    uint32 underlyingSlippageBasisPoints, // Slippage (100 = 1%)
    uint32 debtSlippageBasisPoints,       // Slippage (300 = 3%)
    address defaultConverter,             // ITokenConverter
    address defaultFlashLoanAdapter,      // IFlashLoanAdapter
    address defaultSwapper,               // ISwapper
    address wETH                          // WETH contract
)
```

### V3Leverager

```solidity
V3Leverager(
    address _owner            // Owner/admin for adapter approvals
)
```

