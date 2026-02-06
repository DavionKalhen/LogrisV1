# Alchemix V3 Integration Guide for Leveraged Positions

This document outlines how to integrate Alchemix V3 with our leveraged position system, highlighting key differences from Alchemix V2 and providing implementation guidance.

## Alchemix V3 Overview

Alchemix V3 represents a significant architectural evolution from V2, introducing NFT-based position management and more efficient debt handling. Key components include:

1. **AlchemistV3**: The main contract handling debt, collateral, and yield token interactions.
2. **AlchemistV3Position**: An ERC-721 NFT representing user positions with unique tokenIDs.
3. **Transmuter**: Handles the redemption of debt tokens for underlying assets.
4. **TokenVaults**: Specialized vaults for handling assets (ETH or ERC-20 tokens).

### Key Differences from V2

1. **Position Management**:
   - V2: Account-based system with direct mappings from addresses to positions
   - V3: NFT-based positions with tokenIDs representing each position

2. **Function Signatures**:
   - V2: Functions accept addresses for users
   - V3: Functions require tokenIDs for positions

3. **Collateralization and Liquidation**:
   - V3 introduces more sophisticated collateralization checks and liquidation mechanics

4. **Mint Allowances**:
   - V2: Account-based approvals
   - V3: Version-based allowances tied to position NFTs

## Integration Strategy: Vault + Leverager with Adapters

The current V3 flow uses a generic `V3Leverager` plus adapter registries for flash loans, swaps, and token conversion.

1. **LeveragedVault** owns a single Alchemist V3 position NFT and exposes callback hooks.
2. **V3Leverager** orchestrates leverage/deleverage using approved adapters.
3. **Adapters** are swappable and pre-approved:
   - `ITokenConverter` (underlying ↔ yield)
   - `IFlashLoanAdapter` (Aave/Balancer/Euler, etc.)
   - `ISwapper` (Curve/other DEXes)

## Integration with the Flash Loan Leveraging System

### Setting Up the Leverager and Adapters

1. Deploy the `V3Leverager` and approve adapters:

```solidity
V3Leverager leverager = new V3Leverager(owner);
leverager.setConverterApproval(address(converter), true);
leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
leverager.setSwapperApproval(address(swapper), true);
```

2. Deploy the vault with default adapters:

```solidity
LeveragedVault vault = new LeveragedVault(
    "Leveraged Vault",
    "lVAULT",
    yieldToken,
    underlyingToken,
    alchemistV3,
    address(leverager),
    100, // underlying slippage bps (caller-provided minOuts are enforced)
    300, // debt slippage bps
    address(converter),
    address(flashLoanAdapter),
    address(swapper),
    weth
);
```

### Flash Loan Workflows

1. **Deposit and Leverage**:
   ```
   User -> LeveragedVault -> V3Leverager -> Flash Loan Adapter
                     ↑           ↓
               Vault callbacks    Swapper + Converter
   ```

2. **Withdraw and Deleveraging**:
   ```
   User -> LeveragedVault -> V3Leverager -> Flash Loan Adapter
                     ↑           ↓
               Vault callbacks    Swapper + Converter
   ```

## Implementation Considerations

### Ownership and Permissions

- The V3 NFT position model creates considerations around position ownership and transfers
- Our adapter assumes the user retains ownership of their position NFT
- For multi-user vault strategies, special consideration is needed for managing shared positions

### Error Handling

V3 introduces different error conditions and requirements:

1. Position creation errors
2. Minimum time between mints (per `lastMintBlock`)
3. Different liquidation thresholds

### Gas Optimization

V3 operations may have different gas profiles than V2:

1. Position creation has a one-time cost
2. NFT transfers are more expensive than simple account balance updates
3. State syncing via `poke()` has additional costs

## Testing Recommendations

1. Deploy V3 contracts in a local testnet environment
2. Create adapter and test basic operations (deposit, withdraw, mint, burn)
3. Test flash loan functionality with different scenarios
4. Test edge cases around position creation and management
5. Compare gas costs with V2 implementation

## Future Enhancements

1. **Position Merging**: Add functionality to merge multiple positions for a user
2. **NFT Management**: Provide users with more control over their position NFTs
3. **Multi-yield Token Support**: Extend to support multiple yield tokens per position

## Code Examples

### Example: Creating a Leveraged Position with V3

```javascript
// Set up the leverager
const leverager = await V3Leverager.deploy(owner.address);
await leverager.setConverterApproval(converter.address, true);
await leverager.setFlashLoanAdapterApproval(flashLoanAdapter.address, true);
await leverager.setSwapperApproval(swapper.address, true);

// Set up the vault
const vault = await LeveragedVault.deploy(
  "Leveraged alETH",
  "lalETH",
  yieldToken.address,
  underlyingToken.address,
  alchemistV3.address,
  leverager.address,
  30, // underlying slippage bps
  50, // debt slippage bps
  converter.address,
  flashLoanAdapter.address,
  swapper.address,
  weth.address
);

// Use the vault for leveraged positions
await underlyingToken.approve(vault.address, depositAmount);
await vault.depositUnderlying(depositAmount);

// Leverage the position
await vault.leverage(
  depositAmount,
  flashLoanAmount,
  underlyingDepositMin,
  mintAmount,
  debtTradeMin
);
```

### Example: Querying Position Data

```javascript
// Get the vault's V3 position
const tokenId = await vault.getVaultPositionId();
const accountInfo = await alchemistV3.getAccount(tokenId);
```

## Conclusion

Alchemix V3's architecture represents a significant evolution in debt position management through NFT-based positions. By using our adapter pattern, we can seamlessly integrate this new system with our existing leveraging infrastructure, providing users with improved functionality while maintaining a consistent interface.

The adapter abstracts away the complexity of V3's position management, making it easier for developers to build on top of either version without significant code changes. 