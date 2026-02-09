# Testing Guide

This guide explains how to build, run, and extend the Logris V1 test suite.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Test Categories](#test-categories)
4. [Running Tests](#running-tests)
5. [Fork Tests](#fork-tests)
6. [Writing New Tests](#writing-new-tests)
7. [Shared Mock Infrastructure](#shared-mock-infrastructure)
8. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Git with submodule support
- An Ethereum RPC endpoint for fork tests (optional)

### Setup

```bash
git clone --recursive <repo-url>
cd LogrisV1
forge install
forge build
```

Compiler: Solidity 0.8.26 with `via_ir = true` and `optimizer_runs = 200` (configured in `foundry.toml`).

---

## Quick Start

```bash
# Run all non-fork tests (345 tests, no RPC required)
forge test --no-match-test "Fork|fork"

# Run with verbose output (shows pass/fail per test)
forge test --no-match-test "Fork|fork" -vv

# Run with full trace (shows every internal call)
forge test --no-match-test "Fork|fork" -vvvv
```

---

## Test Categories

The test suite is organized across 19 test files covering different aspects of the system:

### Unit Tests

| File | Tests | Description |
|------|-------|-------------|
| `V3LeveragerModular.t.sol` | 17 | V3Leverager with mocked adapters: registry validation, leverage/deleverage flows, state machine |
| `AdapterUnit.t.sol` | 62 | WstETHAdapter, WETHToWstETHConverter, AaveV3FlashLoan adapter units |
| `CurveSwapperUnit.t.sol` | 6 | CurveSwapper isolated tests |
| `DeleverageUnit.t.sol` | 19 | All three deleverage paths with mocked AlchemistV3 |
| `LeverageErrorPaths.t.sol` | 12 | Error path coverage (capacity exceeded, paused, insufficient balance) |
| `WETHToWstETHConverterConfig.t.sol` | 5 | Converter configuration validation |
| `UnitMismatchTests.t.sol` | 4 | Unit conversion edge cases (rounding, precision) |

### Integration Tests

| File | Tests | Description |
|------|-------|-------------|
| `IntegrationAndInvariant.t.sol` | 16 | Full deposit -> leverage -> withdraw cycle with mocked contracts |
| `LeveragedVaultFactory.t.sol` | 21 | Factory input validation, clone deployment, ownership transfer |
| `LeveragedVaultPause.t.sol` | 9 | Pause blocks deposits/leverage, withdrawals remain available |

### Security Tests

| File | Tests | Description |
|------|-------|-------------|
| `SecurityTests.t.sol` | 18 | Callback spoofing, slippage enforcement, reentrancy attempts |
| `AuditCoverage.t.sol` | 71 | Regression tests for all audit findings (two rounds) |

### Fuzz & Invariant Tests

| File | Tests | Description |
|------|-------|-------------|
| `FuzzTests.t.sol` | 15 | Randomized share math, flash loan bounds, deposit/withdraw symmetry |
| `VaultPositionInvariant.t.sol` | 2 | Position NFT integrity invariants |

### Fork Tests (require RPC endpoint)

| File | Tests | Description |
|------|-------|-------------|
| `V3LeveragerE2E.t.sol` | 12 | E2E with real AlchemistV3, Curve, Lido on mainnet fork |
| `IntegrationFork.t.sol` | varies | Full integration on fork |
| `FlashLoanAdapterFork.t.sol` | varies | Real Balancer/Aave/Euler flash loans |
| `CurveSwapperFork.t.sol` | varies | Real Curve pool swaps |
| `EdgeCases.t.sol` | 17 | Edge cases for flash loan adapters on mainnet fork |

---

## Running Tests

### By Category

```bash
# Unit tests only
forge test --match-contract "ModularTest|AdapterUnit|CurveSwapperUnit|DeleverageUnit|LeverageErrorPaths|ConverterConfig|UnitMismatch" -vv

# Security tests
forge test --match-contract "SecurityTests|AuditCoverage" -vv

# Integration tests
forge test --match-contract "FullIntegration|LeveragedVaultFactory|LeveragedVaultPause|EdgeCase" -vv

# Fuzz tests (increase runs for thorough coverage)
forge test --match-contract "Fuzz|Invariant" -vv

# Audit regression tests specifically
forge test --match-contract AuditCoverageTest -vv
```

### By Test Name

```bash
# Run a specific test function
forge test --match-test test_FullCycle_DepositLeverageWithdraw -vvvv

# Run all tests matching a pattern
forge test --match-test "test_leverage" -vv

# Run all tests in a specific file
forge test --match-path "test/SecurityTests.t.sol" -vv
```

### With Gas Reports

```bash
forge test --no-match-test "Fork|fork" --gas-report
```

### With Coverage

```bash
forge coverage --no-match-test "Fork|fork"
```

---

## Fork Tests

Fork tests run against a real Ethereum mainnet state and interact with actual deployed contracts (AlchemistV3, Curve pools, Lido, Balancer, Aave, Euler).

### Setup

Set your RPC endpoint:

```bash
# Option 1: Environment variable
export ETH_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"

# Option 2: .env file (already in .gitignore)
echo 'ALCHEMY_API_KEY=YOUR_KEY' >> .env
```

### Running Fork Tests

```bash
# All fork tests
forge test --match-test "Fork|fork" -vv

# E2E tests (deploy full Logris stack on fork)
forge test --match-contract V3LeveragerE2ETest -vv

# Flash loan adapter tests (real Balancer/Aave/Euler)
forge test --match-contract FlashLoanAdapterForkTest -vv

# Curve swapper tests (real Curve pools)
forge test --match-contract CurveSwapperForkTest -vv

# All tests including fork
forge test -vv
```

### Fork Test Behavior

- Fork tests automatically use `vm.createSelectFork()` with the configured RPC URL
- They deploy the Logris contracts on top of the forked state
- They interact with real mainnet contracts (Curve pools, Lido, AlchemistV3)
- Rate-limited RPC endpoints may cause 429 errors -- use a dedicated API key

---

## Writing New Tests

### Test File Structure

All test files follow this pattern:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultFactory.sol";
// Import mocks from shared infrastructure
import "./AuditCoverage.t.sol";

contract MyNewTest is Test {
    // Use shared mock infrastructure
    MockAlchemistV3 alchemist;
    MockTokenConverter converter;
    // ... etc

    function setUp() public {
        // Deploy mocks and factory
        // Create vault clone via factory
    }

    function test_MyFeature() public {
        // Test implementation
    }
}
```

### Using the Proxy Clone Pattern in Tests

Tests must use the factory to create vault instances (not deploy directly). The factory's `createVault` is restricted to the factory owner (`onlyOwner`), so ensure your test calls it from the correct address:

```solidity
LeveragedVault implementation = new LeveragedVault();
LeveragedVaultFactory factory = new LeveragedVaultFactory(address(implementation));

// msg.sender must be factory owner (deployer by default)
address vault = factory.createVault(
    address(yieldToken),
    address(underlyingToken),
    address(alchemist),
    address(leverager),
    100,  // 1% underlying slippage
    400,  // 4% debt slippage
    address(converter),
    address(flashLoanAdapter),
    address(swapper),
    address(weth)
);
```

### Working with ERC-7201 Storage in Tests

The vault uses ERC-7201 namespaced storage, which works with Foundry's `stdstore`:

```solidity
// stdstore traces via function calls, so it works with namespaced storage
stdstore.target(address(vault)).sig("vaultPositionId()").checked_write(uint256(42));
```

### Naming Conventions

- Test functions: `test_FeatureName_Scenario` (e.g., `test_Withdraw_Path3_BurnsSharesBeforeExternalCalls`)
- Revert tests: `test_RevertWhen_Condition` (e.g., `test_RevertWhen_DepositZeroAmount`)
- Fuzz tests: `testFuzz_FeatureName` (e.g., `testFuzz_ShareConversion_RoundTrip`)

---

## Shared Mock Infrastructure

The file `test/AuditCoverage.t.sol` contains shared mock contracts used across the test suite:

| Mock | Purpose |
|------|---------|
| `MockAlchemistV3` | Simulates AlchemistV3 position management (deposit, withdraw, mint, burn) |
| `MockAlchemistV3Position` | ERC-721 position NFT mock |
| `MockTokenConverter` | 1:1 conversion between underlying and yield tokens |
| `MockFlashLoanAdapter` | Immediate flash loan with configurable fees |
| `MockSwapper` | Configurable debt <-> underlying swap rates |
| `MockERC20` | Standard ERC-20 token with mint/burn |

Import and use these in your test files:

```solidity
import "./AuditCoverage.t.sol";
```

These mocks provide deterministic behavior for unit tests. For tests requiring real protocol behavior, use fork tests instead.

---

## Troubleshooting

### "Stack too deep" compilation errors

The project uses `via_ir = true` in `foundry.toml` which handles most stack depth issues. If you still encounter this, split complex functions or use struct parameters.

### Fork tests failing with 429 errors

Your RPC endpoint is rate-limited. Solutions:
- Use a dedicated Alchemy/Infura API key
- Reduce concurrent test runners: `forge test --jobs 1`
- Run non-fork tests separately: `forge test --no-match-test "Fork|fork"`

### "EvmError: Revert" with no message

Run with maximum verbosity to see the revert reason:
```bash
forge test --match-test "test_name" -vvvv
```

### Tests pass locally but fail in CI

The GitHub Actions workflow (`.github/workflows/test.yml`) uses `workflow_dispatch` (manual trigger). Ensure your CI has the correct RPC endpoint configured for fork tests, or exclude them:
```bash
forge test --no-match-test "Fork|fork"
```

### Slow compilation

The `via_ir` compiler pass is slower than default. The project requires `via_ir = true` for compilation (several contracts exceed the default stack depth limit), so there is no workaround to skip it. Expect initial compilation to take longer than non-IR projects. Subsequent builds use Foundry's cache and are faster.
