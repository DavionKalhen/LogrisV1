# WETH Parameter Changes

## Overview

Updated all contracts to accept WETH address as constructor parameter instead of hardcoding it. This improves flexibility, testability, and deployment to different networks.

## Files Updated

### Core Contracts

1. **LeveragedVault.sol**
   - Added `address _wETH` parameter to constructor
   - Changed from hardcoded `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` to configurable address
   - Made `depositUnderlying()` and `leverage()` functions virtual for testing

2. **LeveragedVaultFactory.sol**
   - Added `address wETH` parameter to `createVault()` function
   - Updated constructor call to pass WETH address

3. **ILeveragedVaultFactory.sol**
   - Added WETH parameter to `createVault()` interface

### V3 Leverager Contracts

4. **V3Leverager.sol**
   - Added `address public weth` field
   - Added `address _weth` parameter to constructor
   - Removed hardcoded constant `address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`

5. **V3CurveLeverager.sol**
   - Added `address _weth` parameter to constructor
   - Updated parent constructor call

6. **V3BalancerCurveLeverager.sol**
   - Added `address _weth` parameter to constructor
   - Updated parent constructor call

### Test Files

7. **LeveragedVaultTest.t.sol**
   - Updated `MockV3Leverager` constructor to accept WETH parameter
   - Updated test setup to pass WETH address
   - Added `TestLeveragedVault` overrides for proper mock WETH usage
   - Fixed withdrawal logic to use underlying token instead of yield token

### Documentation

8. **ALCHEMIX_V3_INTEGRATION.md**
   - Updated leverager instantiation example to include WETH parameter

## Benefits

1. **Flexibility**: Can deploy to different networks with different WETH addresses
2. **Testability**: Can use mock WETH contracts for testing
3. **Consistency**: All contracts now follow the same pattern of accepting dependencies
4. **Future-proofing**: Easier to adapt to network upgrades or alternative wrapped ETH implementations

## Constructor Changes

### Before
```solidity
// LeveragedVault
constructor(
    string memory tokenName,
    string memory tokenDescription,
    address yieldToken,
    address underlyingTokenAddress,
    address _leverager,
    address _debtSource,
    uint32 _underlyingSlippageBasisPoints,
    uint32 _debtSlippageBasisPoints
)

// V3Leverager
constructor(
    address _alchemistV3,
    address _yieldToken,
    address _underlyingToken
)
```

### After
```solidity
// LeveragedVault
constructor(
    string memory tokenName,
    string memory tokenDescription,
    address yieldToken,
    address underlyingTokenAddress,
    address _leverager,
    address _debtSource,
    uint32 _underlyingSlippageBasisPoints,
    uint32 _debtSlippageBasisPoints,
    address _wETH  // NEW
)

// V3Leverager
constructor(
    address _alchemistV3,
    address _yieldToken,
    address _underlyingToken,
    address _weth  // NEW
)
```

## Testing Status

All 7 tests in `LeveragedVaultTest` pass:
- ✅ testETHDepositToVault
- ✅ testMultipleETHDepositToVault
- ✅ testMultipleUsersETHDepositToVault
- ✅ testETHDepositToVaultWithLeverager
- ✅ testETHDepositToValutWithThreeUsersAndLeverager
- ✅ testETHDepositToValutWithFourUsersAndLeverager
- ✅ testWithdrawUnderlying

## Migration Notes

When deploying to mainnet, use:
- **Ethereum Mainnet**: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- **For testing**: Deploy MockWETH or use test networks' WETH addresses 