# LeveragedVault Implementation Guide
## Complete Fix for Alchemist V3 Flash Loan Integration

### Overview
This guide provides step-by-step instructions to implement a fully functional LeveragedVault system that can be tested on mainnet fork with Alchemist V3. Each implementation unit includes specific unit tests to verify functionality.

---

## 🎯 Implementation Strategy

### Architecture Summary
- **Single Vault Position**: Vault owns one AlchemistV3 position, users own proportional vault shares
- **Callback Pattern**: Leverager calls back to vault for AlchemistV3 interactions
- **Flash Loan Integration**: Real Balancer flash loans with proper authorization flow
- **Proportional Shares**: Fair distribution of leverage gains across all vault users

> **Note:** This guide predates the current `V3Leverager` refactor. The live code now uses
> `V3Leverager` with adapter registries (`ITokenConverter`, `IFlashLoanAdapter`, `ISwapper`),
> and does **not** use `V3BalancerCurveLeverager` or `AlchemixV3DebtAdapter` in the main flow.
> For current integration details, see `docs/alchemix-v3-integration.md`.

---

## 📋 Implementation Units

### **Unit 1: Fix Vault Position Management**
**Files to Modify**: `src/LeveragedVault.sol`, `src/base/AlchemistV3Base.sol`
**Test File**: `test/unit/VaultPositionManagement.t.sol`

#### **Critical Issue**: Authorization chain broken - vault needs callback interface for leverager

#### **Changes Required**:

1. **Add callback interface to LeveragedVault.sol**:
```solidity
// Add vault callback interface
interface ILeveragedVaultCallback {
    function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);
    function vaultMintDebtTokens(uint256 amount, address recipient) external;
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);
    function vaultBurnDebtTokens(uint256 amount) external;
}

contract LeveragedVault is ERC4626, ILeveragedVault, AlchemistV3Base, ILeveragedVaultCallback {
    
    // Add access control for callbacks
    modifier onlyLeverager() {
        require(msg.sender == address(leverager), "Only leverager can call");
        _;
    }
    
    // Implement callback functions
    function vaultDepositYieldTokens(uint256 amount) external onlyLeverager returns (uint256 sharesAdded) {
        if (vaultPositionId == 0) {
            vaultPositionId = _createPosition(address(this), amount);
            emit VaultPositionCreated(vaultPositionId);
            return amount;
        } else {
            _depositToPosition(vaultPositionId, amount, address(this));
            return amount;
        }
    }
    
    function vaultMintDebtTokens(uint256 amount, address recipient) external onlyLeverager {
        require(vaultPositionId > 0, "No vault position exists");
        _mintDebt(vaultPositionId, amount, recipient);
    }
    
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external onlyLeverager returns (uint256 actualWithdrawn) {
        require(vaultPositionId > 0, "No vault position exists");
        return _withdrawCollateral(vaultPositionId, amount, recipient);
    }
    
    function vaultBurnDebtTokens(uint256 amount) external onlyLeverager {
        require(vaultPositionId > 0, "No vault position exists");
        _burnDebt(vaultPositionId, amount);
    }
}
```

2. **Fix leverage() function**:
```solidity
function leverage(uint clampedDeposit,
                  uint flashLoanAmount,
                  uint underlyingDepositMin,
                  uint mintAmount,
                  uint debtTradeMin) external virtual {
    
    require(clampedDeposit > 0, "Must deposit some amount");
    
    // Record state before leverage
    uint256 totalAssetsBefore = totalAssets();
    uint256 totalSupplyBefore = totalSupply();
    
    // Execute leverage through leverager
    leverager.leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    
    // Calculate shares to mint based on leverage gained
    uint256 totalAssetsAfter = totalAssets();
    uint256 leverageGained = totalAssetsAfter > totalAssetsBefore ? totalAssetsAfter - totalAssetsBefore : 0;
    
    uint256 sharesToMint;
    if (totalSupplyBefore == 0) {
        sharesToMint = leverageGained;
    } else {
        sharesToMint = (leverageGained * totalSupplyBefore) / totalAssetsBefore;
    }
    
    _mint(msg.sender, sharesToMint);
    emit VaultLeverageExecuted(msg.sender, leverageGained, sharesToMint);
}
```

#### **Unit Test: test/unit/VaultPositionManagement.t.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/LeveragedVault.sol";
import "../mocks/MockLeverager.sol";
import "../setup/AlchemistV3TestSetup.sol";

contract VaultPositionManagementTest is Test, AlchemistV3TestSetup {
    LeveragedVault public vault;
    MockLeverager public mockLeverager;
    
    function setUp() public {
        setupAlchemistV3();
        mockLeverager = new MockLeverager();
        
        vault = new LeveragedVault(
            "Test Vault",
            "TVAULT",
            address(alchemistV3),
            address(yieldToken),
            address(underlyingToken),
            address(mockLeverager),
            address(debtAdapter),
            100, // 1% slippage
            300, // 3% slippage
            address(wETH)
        );
    }
    
    function testVaultPositionCreation() public {
        uint256 depositAmount = 100 ether;
        
        // Fund vault with yield tokens
        yieldToken.mint(address(vault), depositAmount);
        
        // Simulate leverager calling vault
        vm.startPrank(address(mockLeverager));
        uint256 sharesAdded = vault.vaultDepositYieldTokens(depositAmount);
        vm.stopPrank();
        
        assertGt(vault.vaultPositionId(), 0, "Vault position should be created");
        assertEq(sharesAdded, depositAmount, "Should return correct shares");
        assertEq(positionNFT.ownerOf(vault.vaultPositionId()), address(vault), "Vault should own the position");
    }
    
    function testOnlyLeveragerCanCallCallbacks() public {
        vm.expectRevert("Only leverager can call");
        vault.vaultDepositYieldTokens(100 ether);
    }
}
```

---

### **Unit 2: Implement Flash Loan Integration**
**Files to Modify**: `src/leveragers/V3BalancerCurveLeverager.sol`
**Test File**: `test/unit/FlashLoanIntegration.t.sol`

#### **Critical Issue**: Flash loan callback not implemented, needs proper Balancer integration

#### **Changes Required**:

1. **Complete V3BalancerCurveLeverager.sol**:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./V3Leverager.sol";
import "../interfaces/balancer/IFlashLoanRecipient.sol";
import "../interfaces/balancer/IVault.sol";

contract V3BalancerCurveLeverager is V3Leverager, IFlashLoanRecipient {
    IVault public constant BALANCER_VAULT = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    
    // Add vault callback interface
    interface ILeveragedVaultCallback {
        function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);
        function vaultMintDebtTokens(uint256 amount, address recipient) external;
        function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);
        function vaultBurnDebtTokens(uint256 amount) external;
    }
    
    function _leverageWithFlashLoan(
        uint clampedDeposit,
        uint flashLoanAmount,
        uint underlyingDepositMin,
        uint mintAmount,
        uint debtTradeMin
    ) internal override {
        
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(underlyingToken);
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;
        
        bytes memory userData = abi.encode(
            msg.sender, // vault address
            true, // isLeverage
            clampedDeposit,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin
        );
        
        BALANCER_VAULT.flashLoan(this, tokens, amounts, userData);
    }
    
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        require(msg.sender == address(BALANCER_VAULT), "Only Balancer vault can call");
        
        (
            address vaultAddress,
            bool isLeverage,
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = abi.decode(userData, (address, bool, uint256, uint256, uint256, uint256, uint256));
        
        if (isLeverage) {
            _executeFlashLoanLeverage(
                vaultAddress,
                clampedDeposit,
                flashLoanAmount,
                underlyingDepositMin,
                mintAmount,
                debtTradeMin
            );
        }
        
        // Repay flash loan
        uint256 totalRepayment = amounts[0] + feeAmounts[0];
        IERC20(underlyingToken).transfer(address(BALANCER_VAULT), totalRepayment);
    }
    
    function _executeFlashLoanLeverage(
        address vaultAddress,
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) internal {
        
        // Step 1: Convert underlying to yield tokens
        uint256 totalUnderlying = clampedDeposit + flashLoanAmount;
        uint256 yieldTokensObtained = _convertUnderlyingToYieldTokens(totalUnderlying);
        require(yieldTokensObtained >= underlyingDepositMin, "Insufficient yield tokens from conversion");
        
        // Step 2: Deposit yield tokens to vault's position
        IERC20(yieldToken).approve(vaultAddress, yieldTokensObtained);
        ILeveragedVaultCallback(vaultAddress).vaultDepositYieldTokens(yieldTokensObtained);
        
        // Step 3: Mint debt tokens from vault's position
        ILeveragedVaultCallback(vaultAddress).vaultMintDebtTokens(mintAmount, address(this));
        
        // Step 4: Swap debt tokens to underlying for flash loan repayment
        uint256 underlyingReceived = _swapDebtTokensToUnderlying(mintAmount, debtTradeMin);
        require(underlyingReceived >= flashLoanAmount, "Insufficient underlying to repay flash loan");
    }
}
```

#### **Unit Test: test/unit/FlashLoanIntegration.t.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/leveragers/V3BalancerCurveLeverager.sol";
import "../mocks/MockBalancerVault.sol";
import "../setup/AlchemistV3TestSetup.sol";

contract FlashLoanIntegrationTest is Test, AlchemistV3TestSetup {
    V3BalancerCurveLeverager public leverager;
    MockBalancerVault public mockBalancerVault;
    
    function setUp() public {
        setupAlchemistV3();
        mockBalancerVault = new MockBalancerVault();
        
        leverager = new V3BalancerCurveLeverager(
            address(alchemistV3),
            address(yieldToken),
            address(underlyingToken),
            address(wETH)
        );
    }
    
    function testFlashLoanInitiation() public {
        uint256 flashLoanAmount = 100 ether;
        address mockVault = setupMockVault();
        
        vm.startPrank(mockVault);
        leverager.leverage(
            50 ether, // clampedDeposit
            flashLoanAmount,
            140 ether, // underlyingDepositMin
            75 ether, // mintAmount
            70 ether, // debtTradeMin
            abi.encode(address(0), int128(0), int128(1))
        );
        vm.stopPrank();
        
        assertTrue(mockBalancerVault.flashLoanCalled(), "Flash loan should be initiated");
        assertEq(mockBalancerVault.lastFlashLoanAmount(), flashLoanAmount, "Correct flash loan amount");
    }
}
```

---

### **Unit 3: Implement Proportional Share Calculations**
**Files to Modify**: `src/LeveragedVault.sol`
**Test File**: `test/unit/ProportionalShares.t.sol`

#### **Critical Issue**: Share calculations don't account for leverage efficiency

#### **Changes Required**:

1. **Add advanced share calculation logic**:
```solidity
// Add to LeveragedVault.sol

struct LeverageState {
    uint256 totalCollateral;
    uint256 totalDebt;
    uint256 timestamp;
}

mapping(address => uint256) public userLastLeverageTime;
LeverageState public lastLeverageState;

function calculateLeverageShares(
    uint256 leverageAmount,
    uint256 debtMinted
) internal view returns (uint256 sharesToMint) {
    uint256 currentTotalAssets = totalAssets();
    uint256 currentTotalSupply = totalSupply();
    
    if (currentTotalSupply == 0) {
        return leverageAmount;
    }
    
    // Calculate effective leverage multiplier
    uint256 leverageMultiplier = (leverageAmount * 1e18) / (leverageAmount - debtMinted);
    
    // Adjust shares based on leverage efficiency
    uint256 baseShares = (leverageAmount * currentTotalSupply) / currentTotalAssets;
    uint256 leverageBonus = (baseShares * (leverageMultiplier - 1e18)) / 1e18;
    
    return baseShares + (leverageBonus / 2); // 50% of leverage bonus to prevent gaming
}
```

#### **Unit Test: test/unit/ProportionalShares.t.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/LeveragedVault.sol";
import "../setup/AlchemistV3TestSetup.sol";

contract ProportionalSharesTest is Test, AlchemistV3TestSetup {
    LeveragedVault public vault;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    function setUp() public {
        setupAlchemistV3();
        vault = deployTestVault();
        
        underlyingToken.mint(user1, 1000 ether);
        underlyingToken.mint(user2, 1000 ether);
    }
    
    function testMultiUserProportionalShares() public {
        // User 1: Initial deposit and leverage
        vm.startPrank(user1);
        underlyingToken.approve(address(vault), 200 ether);
        uint256 shares1 = vault.depositUnderlying(200 ether);
        uint256 leverageShares1 = simulateLeverage(user1, 100 ether, 50 ether);
        vm.stopPrank();
        
        // User 2: Deposit after leverage exists
        vm.startPrank(user2);
        underlyingToken.approve(address(vault), 100 ether);
        uint256 shares2 = vault.depositUnderlying(100 ether);
        uint256 leverageShares2 = simulateLeverage(user2, 50 ether, 25 ether);
        vm.stopPrank();
        
        // Verify proportional distribution
        uint256 totalShares = vault.totalSupply();
        uint256 user1Total = shares1 + leverageShares1;
        uint256 user2Total = shares2 + leverageShares2;
        
        assertEq(user1Total + user2Total, totalShares, "Shares should sum to total");
        assertGt(user1Total, user2Total, "User 1 should have more shares");
    }
    
    function simulateLeverage(address user, uint256 leverageAmount, uint256 debtAmount) internal returns (uint256 shares) {
        vm.startPrank(address(vault));
        shares = vault.calculateLeverageShares(leverageAmount, debtAmount);
        vault.mint(user, shares);
        vm.stopPrank();
        return shares;
    }
}
```

---

### **Unit 4: Implement Generic Swap Functionality**
**Files to Create**: `src/interfaces/ISwapper.sol`, `src/swaps/GenericSwapperMock.sol`
**Test File**: `test/unit/GenericSwapFunctionality.t.sol`

#### **Goal**: Decouple leverage flow from any specific DEX. Define a pluggable `ISwapper` interface and a mock reference implementation to enable testing without committing to Curve/Balancer/Uniswap routing.

#### **Changes Required**:

1. **Create ISwapper interface (generic)**:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ISwapper {
    error InsufficientOutput();
    error InvalidTokenPair();
    error ExcessiveSlippage();
    error SwapFailed();
    error InvalidAmount();

    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, address indexed recipient);

    function swapDebtToUnderlying(uint256 debtAmount, uint256 minUnderlyingOut, address recipient, bytes calldata swapData) external returns (uint256 underlyingReceived);
    function swapUnderlyingToDebt(uint256 underlyingAmount, uint256 minDebtOut, address recipient, bytes calldata swapData) external returns (uint256 debtReceived);

    // Optional view helpers for previews/rates
    function previewSwapDebtToUnderlying(uint256 debtAmount) external view returns (uint256 expectedUnderlying, uint256 minimumOutput);
    function previewSwapUnderlyingToDebt(uint256 underlyingAmount) external view returns (uint256 expectedDebt, uint256 minimumOutput);
}
```

2. **Create GenericSwapperMock.sol (DEX-agnostic mock)**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract GenericSwapperMock is Ownable {
    address public immutable debtToken;
    address public immutable underlyingToken;

    uint256 private feeBps = 30;      // 0.30%
    uint256 private slipBps = 100;    // 1.00%

    constructor(address _debt, address _underlying, address _owner) Ownable(_owner) {
        debtToken = _debt;
        underlyingToken = _underlying;
    }

    function setSwapFee(uint256 newFeeBps) external onlyOwner { require(newFeeBps <= 500, "Fee too high"); feeBps = newFeeBps; }
    function setSlippageTolerance(uint256 newSlipBps) external onlyOwner { require(newSlipBps <= 1000, "Tolerance too high"); slipBps = newSlipBps; }

    function swapDebtToUnderlying(uint256 debtAmount, uint256 minUnderlyingOut, address recipient, bytes calldata) external returns (uint256 out) {
        require(debtAmount > 0, "InvalidAmount");
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        out = _apply(debtAmount);
        require(out >= minUnderlyingOut, "InsufficientOutput");
        IERC20(underlyingToken).transfer(recipient, out);
    }

    function swapUnderlyingToDebt(uint256 underlyingAmount, uint256 minDebtOut, address recipient, bytes calldata) external returns (uint256 out) {
        require(underlyingAmount > 0, "InvalidAmount");
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), underlyingAmount);
        out = _apply(underlyingAmount);
        require(out >= minDebtOut, "InsufficientOutput");
        IERC20(debtToken).transfer(recipient, out);
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount) external view returns (uint256 expectedUnderlying, uint256 minimumOutput) {
        expectedUnderlying = _apply(debtAmount);
        minimumOutput = _applySlippage(expectedUnderlying);
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount) external view returns (uint256 expectedDebt, uint256 minimumOutput) {
        expectedDebt = _apply(underlyingAmount);
        minimumOutput = _applySlippage(expectedDebt);
    }

    function _apply(uint256 amount) internal view returns (uint256) {
        uint256 fee = (amount * feeBps) / 10_000;
        return amount - fee; // 1:1 with fee only
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        uint256 slip = (amount * slipBps) / 10_000;
        return amount - slip;
    }
}
```

#### **Unit Test: test/unit/GenericSwapFunctionality.t.sol**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/swaps/GenericSwapperMock.sol";
import "alchemix-v3/src/test/mocks/AlchemicTokenV3.sol";
import "alchemix-v3/src/test/mocks/TestERC20.sol";

contract GenericSwapFunctionalityTest is Test {
    TestERC20 public underlying;
    AlchemicTokenV3 public debt;
    GenericSwapperMock public swapper;

    function setUp() public {
        underlying = new TestERC20(0, 18);
        debt = new AlchemicTokenV3("alUSD", "alUSD", 0);
        swapper = new GenericSwapperMock(address(debt), address(underlying), address(this));

        // Fund swapper with reserves
        debt.setWhitelist(address(this), true);
        debt.mint(address(swapper), 1_000_000 ether);
        underlying.mint(address(swapper), 1_000_000 ether);
    }

    function testSwapDebtToUnderlying() public {
        uint256 amount = 1_000 ether;
        debt.setWhitelist(address(this), true);
        debt.mint(address(this), amount);
        debt.approve(address(swapper), amount);

        (uint256 expected, uint256 minOut) = swapper.previewSwapDebtToUnderlying(amount);
        uint256 out = swapper.swapDebtToUnderlying(amount, minOut, address(this), "");
        assertGe(out, minOut);
        assertLe(out, expected);
    }
}
```

---

### **Unit 5: Integration Testing with Mainnet Fork**
**Files to Create**: `test/integration/MainnetForkTest.t.sol`
**Test File**: `test/integration/MainnetForkTest.t.sol`

#### **Integration Test Setup**:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../../src/LeveragedVault.sol";
import "../../src/leveragers/V3BalancerCurveLeverager.sol";
import "../../src/AlchemixV3DebtAdapter.sol";

contract MainnetForkTest is Test {
    // Mainnet addresses (replace with actual addresses)
    address constant ALCHEMIST_V3 = 0x...; 
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant YIELD_TOKEN = 0x...;
    address constant UNDERLYING_TOKEN = 0x...;
    address constant CURVE_ROUTER = 0x...;
    
    LeveragedVault public vault;
    V3BalancerCurveLeverager public leverager;
    AlchemixV3DebtAdapter public debtAdapter;
    
    address public user1 = address(0x1);
    
    function setUp() public {
        // Fork mainnet at specific block
        vm.createFork("https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY", 18_500_000);
        
        // Deploy contracts
        debtAdapter = new AlchemixV3DebtAdapter(ALCHEMIST_V3);
        
        leverager = new V3BalancerCurveLeverager(
            ALCHEMIST_V3,
            YIELD_TOKEN,
            UNDERLYING_TOKEN,
            WETH
        );
        
        vault = new LeveragedVault(
            "Mainnet Test Vault",
            "MTVAULT",
            ALCHEMIST_V3,
            YIELD_TOKEN,
            UNDERLYING_TOKEN,
            address(leverager),
            address(debtAdapter),
            100, // 1% slippage
            300, // 3% slippage
            WETH
        );
        
        // Fund user with real tokens
        deal(UNDERLYING_TOKEN, user1, 1000 ether);
    }
    
    function testMainnetLeverage() public {
        uint256 depositAmount = 100 ether;
        uint256 flashLoanAmount = 200 ether;
        
        vm.startPrank(user1);
        
        IERC20(UNDERLYING_TOKEN).approve(address(vault), depositAmount);
        uint256 shares = vault.depositUnderlying(depositAmount);
        
        vault.leverage(
            depositAmount,
            flashLoanAmount,
            280 ether, // underlyingDepositMin
            150 ether, // mintAmount
            140 ether, // debtTradeMin
            abi.encode(address(0x123), int128(0), int128(1))
        );
        
        vm.stopPrank();
        
        assertGt(vault.totalAssets(), depositAmount, "Total assets should increase from leverage");
        assertGt(vault.balanceOf(user1), shares, "User should have more shares after leverage");
        assertGt(vault.vaultPositionId(), 0, "Vault should have a position");
        assertLt(vault.getVaultDebtBalance(), 0, "Vault should have debt");
    }
}
```

---

## 🧪 Testing Strategy

### **Test Execution Order**:

1. **Unit Tests** (Run individually):
```bash
forge test --match-path "test/unit/VaultPositionManagement.t.sol" -vv
forge test --match-path "test/unit/FlashLoanIntegration.t.sol" -vv
forge test --match-path "test/unit/ProportionalShares.t.sol" -vv
forge test --match-path "test/unit/SwapFunctionality.t.sol" -vv
```

2. **Integration Tests** (Run with mainnet fork):
```bash
forge test --match-path "test/integration/MainnetForkTest.t.sol" --fork-url $ETH_RPC_URL -vv
```

### **Mock Contracts Required**:

Create in `test/mocks/`:
1. **MockLeverager.sol** - Simple leverager for unit testing
2. **MockBalancerVault.sol** - Mock Balancer vault for flash loan testing
3. **MockCurveRouter.sol** - Mock Curve router for swap testing
4. **MockLeveragedVault.sol** - Mock vault for callback testing

### **Test Setup Files**:

Create in `test/setup/`:
1. **AlchemistV3TestSetup.sol** - Complete Alchemist V3 test environment
2. **TokenTestSetup.sol** - Token deployment and configuration
3. **FlashLoanTestSetup.sol** - Flash loan provider setup

---

## 🚀 Implementation Timeline

### **Week 1: Core Fixes**
- Unit 1: Vault Position Management
- Unit 2: Flash Loan Integration (basic)

### **Week 2: Advanced Features**
- Unit 3: Proportional Share Calculations
- Unit 4: Swap Functionality

### **Week 3: Integration & Testing**
- Unit 5: Mainnet Fork Testing
- End-to-end integration testing

### **Week 4: Production Readiness**
- Security review
- Gas optimization
- Documentation

---

## 📋 Checklist

### **Before Starting**:
- [ ] Set up mainnet fork environment with Anvil
- [ ] Verify Alchemist V3 contract addresses
- [ ] Configure RPC endpoints and API keys
- [ ] Install all dependencies

### **After Each Unit**:
- [ ] All unit tests pass
- [ ] Gas usage is reasonable
- [ ] No compiler warnings
- [ ] Code coverage > 90%

### **Final Integration**:
- [ ] Mainnet fork tests pass
- [ ] Flash loan execution works end-to-end
- [ ] Multi-user scenarios work correctly
- [ ] Slippage protection functions properly
- [ ] Emergency functions work (pause, etc.)

---

## 🔑 Key Success Metrics

1. **Flash Loan Success**: Balancer flash loans execute without authorization errors
2. **Position Management**: Vault can create and manage its own AlchemistV3 position
3. **Share Fairness**: Multi-user leverage shares are distributed proportionally
4. **Swap Integration**: Debt tokens can be swapped to underlying via Curve
5. **Mainnet Compatibility**: All tests pass on mainnet fork with real contracts

This implementation guide provides a systematic approach to fix all critical issues and achieve a fully functional LeveragedVault system for Alchemist V3. 