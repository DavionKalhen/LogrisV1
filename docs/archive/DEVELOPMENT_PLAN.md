# Alchemist V3 Integration Development Plan

## Project Goal

Create a leveraged vault system that allows users to pool funds and automatically create leveraged positions in Alchemist V3 using flash loans for capital efficiency.

## Architecture Overview

- **Alchemist V3**: Uses Position NFTs (tokenId) instead of addresses, direct yield token deposits, 90% LTV
- **Leverage Flow**: Flash loan -> Purchase yield tokens -> Deposit to Alchemist -> Mint debt -> Repay flash loan
- **Multi-User Vault**: ERC4626-based vault pools user deposits for shared leveraged positions
- **Callback Pattern**: Leverager calls vault callbacks for AlchemistV3 interactions

## Development Steps

### Step 0: Architecture Understanding
**Status**: Complete

- [x] Analyzed Alchemist V3 interfaces and documentation
- [x] Understood Position NFT system and yield token requirements
- [x] Identified key differences from V2 (NFT positions, yield tokens, 90% LTV)

### Step 1: Basic Alchemist V3 Integration Contract (Single User)
**Status**: Complete (95%)

**Goal**: Create simple single-user contract for basic Alchemist V3 operations

**Files**:
- [x] `src/BasicAlchemistV3Integrator.sol` - Core integration contract
- [x] `test/BasicAlchemistV3Integrator.t.sol` - Tests with real AlchemistV3 deployment

**Key Features**:
- [x] Deposit yield tokens and create position (recipientId=0)
- [x] Mint debt tokens against position
- [x] Withdraw collateral from position
- [x] Repay debt with yield tokens (1 test failing - earmarking system issue)
- [x] Query position information
- [x] Handle position NFT automatically

**Test Results**: **13/14 tests passing**

**Known Issue**:
- The `repay()` function fails with `ECRecover::queryGraph(2, 2)` error, related to Alchemist V3's earmarking/redemption graph system not being properly initialized in test environment

### Step 2: Leverage Calculation Contract
**Status**: Complete

**Goal**: Calculate optimal leverage parameters for Alchemist V3

**Files**:
- [x] `src/AlchemistV3LeverageCalculator.sol`
- [x] `test/AlchemistV3LeverageCalculator.t.sol`

**Key Features**:
- [x] Calculate maximum leverage based on V3's 90% LTV (~10x theoretical, ~9x practical)
- [x] Determine required flash loan amount for target leverage
- [x] Handle V3-specific conversion rates (yield tokens <-> debt tokens)
- [x] Account for slippage protection in leverage calculations
- [x] Calculate deleveraging parameters
- [x] Optimal leverage calculation with risk tolerance
- [x] Current position leverage and health monitoring

**Test Results**: **13/13 tests passing**

### Step 3: Multi-User Vault with Mock Testing
**Status**: Complete

**Goal**: Implement LeveragedVault with enhanced mock contracts

**Files**:
- [x] `src/LeveragedVault.sol` - Core vault with ERC4626 + callbacks
- [x] `src/base/AlchemistV3Base.sol` - Base V3 operations
- [x] `src/leveragers/V3Leverager.sol` - Abstract leverager base
- [x] `src/leveragers/V3CurveLeverager.sol` - Curve integration
- [x] `test/LeveragedVaultTest.t.sol` - Complete test suite with mocks

**Key Features**:
- [x] ERC4626 vault pooling user deposits
- [x] Single Alchemist V3 position for entire vault
- [x] Callback interface (ILeveragedVaultCallback) for leverager interactions
- [x] Proportional share calculation with efficiency bonuses
- [x] WETH parameter support for flexibility

**Test Results**: **6/6 tests passing**

### Step 4: Flash Loan Integration
**Status**: Complete

**Goal**: Complete flash loan integration with real Balancer/Curve

**Files**:
- [x] `src/leveragers/BalancerCurveLeverager.sol` - Balancer + Curve integration
- [x] `src/interfaces/balancer/IFlashLoanRecipient.sol` - Flash loan callback interface
- [x] `src/interfaces/balancer/IVault.sol` - Balancer vault interface
- [x] `script/start-local.sh` - Local testing environment
- [x] `script/DeployLocal.s.sol` - Local deployment script

**Key Features**:
- [x] Balancer flash loan callback implementation
- [x] Curve swap integration for debt token conversion
- [x] Local testing environment with mainnet fork

### Step 5: Mainnet Fork Testing
**Status**: Pending

**Goal**: Validate complete system on mainnet fork with real contracts

**Files**:
- [ ] `test/integration/MainnetForkTest.t.sol`

**Key Features**:
- [ ] Real Alchemist V3 contract interaction
- [ ] Real Balancer flash loans
- [ ] Real Curve swaps
- [ ] Gas optimization validation

### Step 6: Security & Edge Cases
**Status**: Pending

**Goal**: Comprehensive security testing and audit preparation

**Key Features**:
- [ ] Reentrancy protection validation
- [ ] Access control verification
- [ ] Slippage attack prevention
- [ ] Position ownership security
- [ ] Flash loan repayment guarantees

### Step 7: Production Deployment
**Status**: Pending

**Goal**: Deploy to mainnet with monitoring

**Key Features**:
- [ ] Deploy factory and initial vaults
- [ ] Contract verification
- [ ] Monitoring setup
- [ ] Emergency procedures

## Current Project Status

**Overall Progress**: Steps 0-4 Complete, Step 5 In Progress

| Step | Status | Tests |
|------|--------|-------|
| Step 0: Architecture | Complete | N/A |
| Step 1: Basic V3 Integration | Complete | Run `forge test` |
| Step 2: Leverage Calculator | Complete | Run `forge test` |
| Step 3: Multi-User Vault | Complete | Run `forge test` |
| Step 4: Flash Loan Integration | Complete | Local fork testing |
| Step 5: Mainnet Fork Testing | In Progress | - |
| Step 6: Security & Edge Cases | Pending | - |
| Step 7: Production Deployment | Pending | - |

## Key Technical Decisions

### Position Management
- Single position per contract in Steps 1-2
- Single position per vault in Step 3+ (shared by all users)
- Vault owns Alchemist V3 position NFT

### Flash Loan Source
- Selected: Balancer (0.09% fee)
- Implemented in V3BalancerCurveLeverager

### Swap Integration
- Primary: Curve for debt token swaps
- Interface: ISwapper for DEX-agnostic swapping

### Leverage Efficiency Bonuses
- Flash loan bonus: 5%
- Leverage bonus: 2% per unit of leverage
- Risk bonus: 1% per 10% debt ratio
- Max cap: 25% of base shares

## Architecture Diagram

```
┌─────────────────────────────────────┐
│     LeveragedVault (ERC4626)        │
│  • Pools user deposits               │
│  • Manages single Alchemist position │
│  • Calculates leverage bonuses       │
│  • Implements ILeveragedVaultCallback│
└──────────────┬──────────────────────┘
               │
      ┌────────┴────────┐
      │                 │
      ▼                 ▼
┌─────────────┐   ┌──────────────────┐
│ AlchemistV3 │   │ V3CurveLeverager │
│ Base        │   │                  │
│ • Position  │   │ • Flash loan     │
│   mgmt      │   │ • Swaps          │
│ • Debt ops  │   │ • Callbacks      │
└─────────────┘   └──────────────────┘
      │                 │
      └────────┬────────┘
               │
      ┌────────▼──────────┐
      │  AlchemistV3      │
      │  • CDP storage    │
      │  • Debt minting   │
      │  • Collateral     │
      │  • Position NFTs  │
      └───────────────────┘
```

## Notes

- All contracts are V3-only (no V2 compatibility layer)
- Tests use enhanced mock contracts that closely mimic real V3 behavior
- Multi-user functionality uses proportional share distribution
- WETH address is now a constructor parameter for flexibility
