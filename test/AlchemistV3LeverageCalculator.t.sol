// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/AlchemistV3LeverageCalculator.sol";
import "alchemix-v3/src/test/mocks/TestERC20.sol";
import "alchemix-v3/src/test/mocks/TestYieldToken.sol";
import "alchemix-v3/src/test/mocks/AlchemicTokenV3.sol";

/**
 * @title TestAlchemistV3
 * @notice Minimal AlchemistV3 implementation for unit testing the calculator
 * @dev Only implements the view functions needed by AlchemistV3LeverageCalculator
 */
contract TestAlchemistV3 {
    address public underlyingToken;
    address public yieldToken;
    address public debtToken;
    uint256 public minimumCollateralization;

    constructor(
        address _underlyingToken,
        address _yieldToken,
        address _debtToken,
        uint256 _minimumCollateralization
    ) {
        underlyingToken = _underlyingToken;
        yieldToken = _yieldToken;
        debtToken = _debtToken;
        minimumCollateralization = _minimumCollateralization;
    }

    function convertYieldTokensToUnderlying(uint256 yieldTokenAmount) external pure returns (uint256) {
        return yieldTokenAmount; // 1:1 for testing
    }

    function convertYieldTokensToDebt(uint256 yieldTokenAmount) external pure returns (uint256) {
        return yieldTokenAmount; // 1:1 for testing
    }

    function convertDebtTokensToYield(uint256 debtTokenAmount) external pure returns (uint256) {
        return debtTokenAmount; // 1:1 for testing
    }

    function normalizeDebtTokensToUnderlying(uint256 debtTokenAmount) external pure returns (uint256) {
        return debtTokenAmount; // 1:1 for testing
    }
}

contract AlchemistV3LeverageCalculatorTest is Test {
    AlchemistV3LeverageCalculator public calculator;
    TestAlchemistV3 public alchemist;
    TestERC20 public underlyingToken;
    TestYieldToken public yieldToken;
    AlchemicTokenV3 public debtToken;

    uint256 constant PRECISION = 1e18;
    uint256 constant BASIS_POINTS = 10_000;
    
    // Alchemist v3 parameters
    uint256 constant MIN_COLLATERALIZATION = 1111111111111111111; // ~90% LTV (1/0.9)
    
    function setUp() public {
        // Deploy tokens
        underlyingToken = new TestERC20(0, 18); // amount, decimals
        yieldToken = new TestYieldToken(address(underlyingToken)); // only underlying token address
        debtToken = new AlchemicTokenV3("Alchemic USD", "alUSD", 100); // name, symbol, flashFee
        
        // Deploy mock Alchemist
        alchemist = new TestAlchemistV3(
            address(underlyingToken),
            address(yieldToken),
            address(debtToken),
            MIN_COLLATERALIZATION
        );
        
        // Deploy calculator
        calculator = new AlchemistV3LeverageCalculator(address(alchemist));
        
        console.log("Setup complete:");
        console.log("- Min Collateralization:", MIN_COLLATERALIZATION);
        console.log("- Expected Max Leverage:", (MIN_COLLATERALIZATION * PRECISION) / (MIN_COLLATERALIZATION - PRECISION));
    }
    
    function testGetMaxLeverageMultiplier() public view {
        uint256 maxMultiplier = calculator.getMaxLeverageMultiplier();
        
        // With 90% LTV (min collateralization = 1.111), max leverage should be ~10x
        uint256 expectedMax = (MIN_COLLATERALIZATION * PRECISION) / (MIN_COLLATERALIZATION - PRECISION);
        
        assertEq(maxMultiplier, expectedMax, "Max leverage multiplier incorrect");
        assertGt(maxMultiplier, 9 * PRECISION, "Max leverage should be > 9x");
        assertLt(maxMultiplier, 11 * PRECISION, "Max leverage should be < 11x");
        
        console.log("Max Leverage Multiplier:", maxMultiplier / PRECISION, "x");
    }
    
    function testGetPracticalMaxLeverageMultiplier() public view {
        uint256 safetyBuffer = 500; // 5%
        uint256 practicalMax = calculator.getPracticalMaxLeverageMultiplier(safetyBuffer);
        uint256 theoreticalMax = calculator.getMaxLeverageMultiplier();
        
        // Should be 95% of theoretical max
        uint256 expectedPractical = (theoreticalMax * (BASIS_POINTS - safetyBuffer)) / BASIS_POINTS;
        
        assertEq(practicalMax, expectedPractical, "Practical max leverage incorrect");
        assertLt(practicalMax, theoreticalMax, "Practical max should be less than theoretical max");
        
        console.log("Theoretical Max:", theoreticalMax / PRECISION, "x");
        console.log("Practical Max (5% buffer):", practicalMax / PRECISION, "x");
    }
    
    function testCalculateFlashLoanForLeverage() public view {
        uint256 initialYieldTokens = 1000 * PRECISION;
        uint256 targetMultiplier = 5 * PRECISION; // 5x leverage
        
        (uint256 flashLoanAmount, uint256 totalYieldTokensNeeded, uint256 debtAmount) = 
            calculator.calculateFlashLoanForLeverage(initialYieldTokens, targetMultiplier);
        
        // Total yield tokens should be 5x initial
        assertEq(totalYieldTokensNeeded, initialYieldTokens * 5, "Total yield tokens incorrect");
        
        // Flash loan should be for the additional 4x tokens
        uint256 additionalYieldTokens = totalYieldTokensNeeded - initialYieldTokens;
        uint256 expectedFlashLoan = additionalYieldTokens; // 1:1 conversion in mock
        assertEq(flashLoanAmount, expectedFlashLoan, "Flash loan amount incorrect");
        
        // Debt amount should respect minimum collateralization
        uint256 maxDebtValue = (totalYieldTokensNeeded * PRECISION) / MIN_COLLATERALIZATION;
        assertEq(debtAmount, maxDebtValue, "Debt amount incorrect");
        
        console.log("Initial Yield Tokens:", initialYieldTokens / PRECISION);
        console.log("Total Yield Tokens Needed:", totalYieldTokensNeeded / PRECISION);
        console.log("Flash Loan Amount:", flashLoanAmount / PRECISION);
        console.log("Debt Amount:", debtAmount / PRECISION);
    }
    
    function testCalculateFlashLoanForLeverageExceedsMax() public {
        uint256 initialYieldTokens = 1000 * PRECISION;
        uint256 maxMultiplier = calculator.getMaxLeverageMultiplier();
        uint256 excessiveMultiplier = maxMultiplier + 1; // Just over max
        
        vm.expectRevert(AlchemistV3LeverageCalculator.ExceedsMaxLeverage.selector);
        calculator.calculateFlashLoanForLeverage(initialYieldTokens, excessiveMultiplier);
    }
    
    function testCalculateFlashLoanForLeverageInvalidInputs() public {
        // Test zero initial amount
        vm.expectRevert(AlchemistV3LeverageCalculator.InvalidAmount.selector);
        calculator.calculateFlashLoanForLeverage(0, 2 * PRECISION);
        
        // Test invalid multiplier (less than 1x)
        vm.expectRevert(AlchemistV3LeverageCalculator.InvalidMultiplier.selector);
        calculator.calculateFlashLoanForLeverage(1000 * PRECISION, PRECISION / 2);
    }
    
    function testCalculateLeverageWithSlippage() public view {
        uint256 initialYieldTokens = 1000 * PRECISION;
        uint256 targetMultiplier = 3 * PRECISION; // 3x leverage
        uint256 slippageBps = 100; // 1% slippage
        
        LeverageParams memory params = calculator.calculateLeverageWithSlippage(
            initialYieldTokens,
            targetMultiplier,
            slippageBps
        );
        
        // Verify basic calculations
        assertEq(params.initialYieldTokens, initialYieldTokens, "Initial yield tokens incorrect");
        assertEq(params.targetMultiplier, targetMultiplier, "Target multiplier incorrect");
        assertEq(params.actualMultiplier, targetMultiplier, "Actual multiplier should match target");
        
        // Verify slippage protection
        uint256 additionalYieldTokens = params.totalYieldTokensNeeded - initialYieldTokens;
        uint256 expectedMinFromSwap = additionalYieldTokens - (additionalYieldTokens * slippageBps) / BASIS_POINTS;
        assertEq(params.minYieldTokensFromSwap, expectedMinFromSwap, "Min yield tokens from swap incorrect");
        
        // Verify flash loan can be repaid
        assertGe(params.minUnderlyingFromDebtSwap, params.flashLoanAmount, "Cannot repay flash loan");
        
        console.log("Leverage Params:");
        console.log("- Flash Loan Amount:", params.flashLoanAmount / PRECISION);
        console.log("- Total Yield Tokens Needed:", params.totalYieldTokensNeeded / PRECISION);
        console.log("- Min Yield Tokens From Swap:", params.minYieldTokensFromSwap / PRECISION);
        console.log("- Debt To Mint:", params.debtToMint / PRECISION);
    }
    
    function testCalculateDeleveraging() public view {
        uint256 currentYieldTokens = 5000 * PRECISION; // 5x leverage position
        uint256 currentDebt = 4000 * PRECISION;
        uint256 targetMultiplier = 2 * PRECISION; // Reduce to 2x leverage
        uint256 slippageBps = 100; // 1% slippage
        
        DeleverageParams memory params = calculator.calculateDeleveraging(
            currentYieldTokens,
            currentDebt,
            targetMultiplier,
            slippageBps
        );
        
        // Target debt should be less than current debt
        assertLt(params.targetDebt, currentDebt, "Target debt should be less than current");
        
        // Should have debt to repay
        assertGt(params.debtToRepay, 0, "Should have debt to repay");
        assertEq(params.debtToRepay, currentDebt - params.targetDebt, "Debt to repay calculation incorrect");
        
        // Should have yield tokens to withdraw
        assertGt(params.yieldTokensToWithdraw, 0, "Should have yield tokens to withdraw");
        
        console.log("Deleveraging Params:");
        console.log("- Current Debt:", currentDebt / PRECISION);
        console.log("- Target Debt:", params.targetDebt / PRECISION);
        console.log("- Debt To Repay:", params.debtToRepay / PRECISION);
        console.log("- Yield Tokens To Withdraw:", params.yieldTokensToWithdraw / PRECISION);
    }
    
    function testCalculateOptimalLeverage() public view {
        uint256 initialAmount = 1000 * PRECISION;
        uint256 riskToleranceBps = 7000; // 70% risk tolerance (aggressive)
        uint256 maxGasCostEth = 0.01 ether;
        uint256 baseApyBps = 500; // 5% base APY
        
        (uint256 optimalMultiplier, uint256 estimatedApy) = calculator.calculateOptimalLeverage(
            initialAmount,
            riskToleranceBps,
            maxGasCostEth,
            baseApyBps
        );
        
        // Should be reasonable leverage (between 1x and max)
        assertGe(optimalMultiplier, PRECISION, "Optimal leverage should be at least 1x");
        assertLe(optimalMultiplier, calculator.getMaxLeverageMultiplier(), "Optimal leverage should not exceed max");
        
        // Should have estimated APY
        assertGt(estimatedApy, 0, "Should have positive estimated APY");
        
        console.log("Optimal Leverage:", optimalMultiplier / PRECISION, "x");
        console.log("Estimated APY:", estimatedApy / 100, "%");
    }
    
    function testGetCurrentLeverage() public view {
        // Test no leverage (no debt)
        (uint256 multiplier1, bool healthy1) = calculator.getCurrentLeverage(1000 * PRECISION, 0);
        assertEq(multiplier1, PRECISION, "No debt should be 1x leverage");
        assertTrue(healthy1, "Position with no debt should be healthy");
        
        // Test 2x leverage
        uint256 collateral = 2000 * PRECISION;
        uint256 debt = 1000 * PRECISION;
        (uint256 multiplier2, bool healthy2) = calculator.getCurrentLeverage(collateral, debt);
        
        // Calculate expected multiplier: collateralValue / (collateralValue - debt)
        // With 1:1 conversion, should be 2000 / (2000 - 1000) = 2x
        assertEq(multiplier2, 2 * PRECISION, "2x leverage calculation incorrect");
        assertTrue(healthy2, "2x leverage should be healthy");
        
        // Test unhealthy position (high debt)
        uint256 highDebt = 1900 * PRECISION; // Very high debt relative to collateral
        (uint256 multiplier3, bool healthy3) = calculator.getCurrentLeverage(collateral, highDebt);
        assertFalse(healthy3, "High debt position should be unhealthy");
        
        console.log("Current Leverage Tests:");
        console.log("- No debt: ", multiplier1 / PRECISION, "x, healthy:", healthy1);
        console.log("- Normal debt:", multiplier2 / PRECISION, "x, healthy:", healthy2);
        console.log("- High debt:", multiplier3 / PRECISION, "x, healthy:", healthy3);
    }
    
    function testGetCurrentLeverageEdgeCases() public view {
        // Test zero collateral
        (uint256 multiplier, bool healthy) = calculator.getCurrentLeverage(0, 0);
        assertEq(multiplier, 0, "Zero collateral should have 0 multiplier");
        assertTrue(healthy, "Zero collateral should be healthy");
        
        // Test zero collateral with debt (should not happen in practice)
        (uint256 multiplier2, bool healthy2) = calculator.getCurrentLeverage(0, 100 * PRECISION);
        assertEq(multiplier2, 0, "Zero collateral should have 0 multiplier even with debt");
        assertTrue(healthy2, "Function should handle edge case gracefully");
    }
    
    function testSlippageCalculations() public view {
        uint256 amount = 1000 * PRECISION;
        uint256 slippageBps = 250; // 2.5%
        
        // Test slippage protection indirectly through calculateLeverageWithSlippage
        uint256 initialYieldTokens = amount;
        uint256 targetMultiplier = 2 * PRECISION; // 2x leverage
        
        LeverageParams memory params = calculator.calculateLeverageWithSlippage(
            initialYieldTokens,
            targetMultiplier,
            slippageBps
        );
        
        // Verify slippage protection was applied
        uint256 additionalYieldTokens = params.totalYieldTokensNeeded - initialYieldTokens;
        uint256 expectedMinFromSwap = additionalYieldTokens - (additionalYieldTokens * slippageBps) / BASIS_POINTS;
        assertEq(params.minYieldTokensFromSwap, expectedMinFromSwap, "Slippage protection not applied correctly");
        
        console.log("Slippage Tests (2.5%):");
        console.log("- Additional Yield Tokens:", additionalYieldTokens / PRECISION);
        console.log("- Min From Swap (protected):", params.minYieldTokensFromSwap / PRECISION);
    }
    
    function testFuzzCalculateFlashLoanForLeverage(
        uint256 initialAmount,
        uint256 multiplier
    ) public view {
        // Bound inputs to reasonable ranges
        initialAmount = bound(initialAmount, 1 * PRECISION, 1_000_000 * PRECISION);
        uint256 maxMultiplier = calculator.getMaxLeverageMultiplier();
        multiplier = bound(multiplier, PRECISION + 1, maxMultiplier - 1); // Start from > 1x to ensure flash loan needed
        
        (uint256 flashLoanAmount, uint256 totalYieldTokensNeeded, uint256 debtAmount) = 
            calculator.calculateFlashLoanForLeverage(initialAmount, multiplier);
        
        // Verify basic invariants
        assertEq(totalYieldTokensNeeded, (initialAmount * multiplier) / PRECISION, "Total yield tokens should match multiplier");
        assertGe(totalYieldTokensNeeded, initialAmount, "Total should be >= initial");
        assertGt(flashLoanAmount, 0, "Should need flash loan for leverage > 1x");
        assertGt(debtAmount, 0, "Should have debt for leverage > 1x");
    }
    
    function testFuzzLeverageCalculations(
        uint256 initialAmount,
        uint256 slippageBps
    ) public view {
        // Bound inputs to reasonable ranges
        initialAmount = bound(initialAmount, 1 * PRECISION, 1_000_000 * PRECISION);
        slippageBps = bound(slippageBps, 0, 1000); // 0-10% slippage
        
        uint256 targetMultiplier = 2 * PRECISION; // 2x leverage
        
        LeverageParams memory params = calculator.calculateLeverageWithSlippage(
            initialAmount,
            targetMultiplier,
            slippageBps
        );
        
        // Verify slippage protection decreases expected amounts
        uint256 additionalYieldTokens = params.totalYieldTokensNeeded - initialAmount;
        assertLe(params.minYieldTokensFromSwap, additionalYieldTokens, "Slippage protection should decrease expected amount");
    }
}