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

## Integration Strategy: Adapter Pattern

We've implemented an adapter pattern to maintain compatibility with our existing leveraging system:

1. The `IDebtTokenAdapter` interface provides a standardized way to interact with debt token systems
2. Our new `AlchemixV3DebtAdapter` implements this interface for V3
3. This allows our `Leverager` and `LeveragedVault` contracts to work with both V2 and V3

## AlchemixV3DebtAdapter Implementation

The `AlchemixV3DebtAdapter` handles the translation between our system's account-based approach and V3's NFT-based positions:

```solidity
// Main responsibilities
contract AlchemixV3DebtAdapter is IDebtTokenAdapter {
    // Maps user addresses to their V3 position tokenIDs
    mapping(address => uint256) private _positionIds;
    
    // Gets or creates a V3 position for a user
    function getOrCreatePositionId(address account) public returns (uint256);
    
    // Adapter functions convert between systems
    function positions(address account, address yieldToken) external view override returns (uint256, uint256);
    function accounts(address account) external view override returns (int256, uint256);
    // etc...
}
```

### Position Management

The adapter maintains a mapping from user addresses to V3 position tokenIDs, creating positions as needed:

```solidity
function getOrCreatePositionId(address account) public returns (uint256) {
    if (_positionIds[account] == 0) {
        // Create a new position for this account if none exists
        uint256 tokenId = IAlchemistV3Position(alchemistV3.alchemistPositionNFT()).mint(account);
        _positionIds[account] = tokenId;
    }
    return _positionIds[account];
}
```

## Integration with Flash Loan Leveraging System

### Setting Up the Adapter

1. Deploy the `AlchemixV3DebtAdapter` with the AlchemistV3 contract address:

```solidity
AlchemixV3DebtAdapter adapter = new AlchemixV3DebtAdapter(alchemistV3Address);
```

2. Set yield token to underlying token pairs:

```solidity
adapter.setYieldTokenUnderlyingPair(yieldTokenAddress, underlyingTokenAddress);
```

3. Update your `Leverager` implementations to use the adapter:

```solidity
constructor(
    address _yieldToken,
    address _underlyingToken,
    address _debtToken,
    address _debtAdapter
)
```

### Flash Loan Workflows

The flash loan leveraging process works similarly with both V2 and V3, but with different adapter implementations:

1. **Deposit and Leverage**:
   ```
   User -> LeveragedVault -> Leverager -> Flash Loan -> AlchemixV3DebtAdapter -> AlchemistV3
   ```

2. **Withdraw and Deleveraging**:
   ```
   User -> LeveragedVault -> Leverager -> Flash Loan -> AlchemixV3DebtAdapter -> AlchemistV3
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
// Set up the adapter
const adapter = await AlchemixV3DebtAdapter.deploy(alchemistV3.address);
await adapter.setYieldTokenUnderlyingPair(yieldToken.address, underlyingToken.address);

// Set up the leverager
const leverager = await BalancerCurveLeverager.deploy(
  yieldToken.address,
  underlyingToken.address,
  debtToken.address,
  adapter.address
);

// Set up the vault
const vault = await LeveragedVault.deploy(
  "Leveraged alETH",
  "lalETH",
  yieldToken.address,
  underlyingToken.address,
  leverager.address,
  adapter.address,
  30, // 0.3% slippage
  50  // 0.5% slippage
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
  debtTradeMin,
  swapParams
);
```

### Example: Querying Position Data

```javascript
// Get a user's V3 position
const tokenId = await adapter.getPositionId(userAddress);
const accountInfo = await alchemistV3.getAccount(tokenId);

// Get information through the adapter (compatible with V2 interface)
const [shares, lastWeight] = await adapter.positions(userAddress, yieldToken.address);
const [debt, lastUpdate] = await adapter.accounts(userAddress);
const borrowCapacity = await leverager.getBorrowCapacity(userAddress);
```

## Conclusion

Alchemix V3's architecture represents a significant evolution in debt position management through NFT-based positions. By using our adapter pattern, we can seamlessly integrate this new system with our existing leveraging infrastructure, providing users with improved functionality while maintaining a consistent interface.

The adapter abstracts away the complexity of V3's position management, making it easier for developers to build on top of either version without significant code changes. 