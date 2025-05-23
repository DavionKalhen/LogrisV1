# Alchemix V3 Integration Guide

This document explains how we've adapted our flash loan-based leveraging system to work with Alchemix V3.

## Overview of Changes

Alchemix V3 introduces a major architectural change from V2:

- **Alchemix V2**: Used account-based positions where each user had a direct account position in the Alchemist contract
- **Alchemix V3**: Uses NFT-based positions where each position is represented by an ERC-721 token

Our adapter bridges this architectural difference transparently, allowing our flash loan system to work with both V2 and V3 implementations.

## Key Components

1. **AlchemixV3DebtAdapter**: Implements the `IDebtTokenAdapter` interface for Alchemix V3
2. **Position Mapping**: Maps user addresses to their V3 position token IDs
3. **Automatic Position Creation**: Creates NFT positions automatically when needed
4. **Leveragers**: Modified to work with both V2 and V3 adapters

## Using the Adapter

### Initialization

```solidity
// Deploy the adapter
AlchemixV3DebtAdapter adapter = new AlchemixV3DebtAdapter(ALCHEMIST_V3_ADDRESS);

// Set yield token to underlying token mapping
adapter.setYieldTokenUnderlyingPair(YIELD_TOKEN, UNDERLYING_TOKEN);

// Initialize the leverager with the adapter
BalancerCurveLeverager leverager = new BalancerCurveLeverager(
    YIELD_TOKEN,
    UNDERLYING_TOKEN,
    DEBT_TOKEN,
    address(adapter)
);
```

### Performing Flash Loan Operations

```solidity
// Approve the adapter to mint from your position
adapter.approveMint(address(leverager), AMOUNT);

// Perform a leveraged deposit using flash loan
bytes memory swapParams = abi.encode(/* Curve swap parameters */);
leverager.leverageAtomic(
    DEPOSIT_AMOUNT,
    UNDERLYING_SLIPPAGE_BPS,
    DEBT_SLIPPAGE_BPS,
    swapParams
);

// Withdraw using flash loan if needed
leverager.withdrawUnderlyingAtomic(
    SHARES_TO_WITHDRAW,
    UNDERLYING_SLIPPAGE_BPS,
    DEBT_SLIPPAGE_BPS,
    swapParams
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

Our adapter maintains a mapping of user addresses to their position token IDs:

```solidity
mapping(address => uint256) private _positionIds;
```

When a user interacts with the system:
1. We check if they have a position
2. If not, we create one automatically
3. We use their position for all subsequent operations

This approach allows our account-based leveraging system to work seamlessly with Alchemix V3's NFT-based positions.

## Flash Loan Example

Here's how a flash loan operation works with Alchemix V3:

1. User initiates leverageAtomic()
2. System takes a flash loan of underlying tokens
3. AlchemixV3DebtAdapter creates or retrieves user's position token ID
4. Deposits flash loan + user deposit into user's position
5. Mints debt tokens against the position
6. Swaps debt tokens for underlying tokens
7. Repays flash loan
8. User now has a leveraged position in Alchemix V3

## Testing

Tests are available in `test/AlchemixV3Test.t.sol` that verify:
- Position creation
- Flash loan deposit
- Flash loan withdrawal

Run the tests with:
```
forge test --match-contract AlchemixV3Test -vvv
``` 