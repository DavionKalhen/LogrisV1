// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @notice Simple interface for Alchemist v3 conversion functions needed by calculator
 */
interface IAlchemistV3Calculator {
    function minimumCollateralization() external view returns (uint256);
    function convertYieldTokensToUnderlying(uint256 yieldTokenAmount) external view returns (uint256);
    function convertYieldTokensToDebt(uint256 yieldTokenAmount) external view returns (uint256);
    function convertDebtTokensToYield(uint256 debtTokenAmount) external view returns (uint256);
    function normalizeDebtTokensToUnderlying(uint256 debtTokenAmount) external view returns (uint256);
}

/**
 * @title AlchemistV3LeverageCalculator
 * @notice Calculates optimal leverage parameters for Alchemist v3 positions
 * @dev Handles the mathematics of leverage calculation with 90% LTV and conversion rates
 */
contract AlchemistV3LeverageCalculator {
    
    // Constants
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;
    
    // Alchemist v3 contract
    IAlchemistV3Calculator public immutable alchemist;
    
    // Events
    event LeverageCalculated(
        uint256 initialAmount,
        uint256 targetMultiplier,
        uint256 flashLoanAmount,
        uint256 totalDeposit,
        uint256 totalDebt
    );
    
    // Errors
    error InvalidMultiplier();
    error InvalidAmount();
    error ExceedsMaxLeverage();
    error InsufficientCollateralization();
    
    /**
     * @notice Constructor
     * @param _alchemist Address of the AlchemistV3 contract
     */
    constructor(address _alchemist) {
        alchemist = IAlchemistV3Calculator(_alchemist);
    }
    
    /**
     * @notice Calculate maximum theoretical leverage multiplier
     * @dev Based on minimum collateralization ratio
     * @return maxMultiplier Maximum leverage multiplier (e.g., 10e18 for 10x)
     */
    function getMaxLeverageMultiplier() external view returns (uint256 maxMultiplier) {
        return _getMaxLeverageMultiplier();
    }
    
    /**
     * @notice Calculate practical maximum leverage (with safety buffer)
     * @param safetyBufferBps Safety buffer in basis points (e.g., 500 = 5%)
     * @return practicalMaxMultiplier Safe maximum leverage multiplier
     */
    function getPracticalMaxLeverageMultiplier(uint256 safetyBufferBps) 
        external 
        view 
        returns (uint256 practicalMaxMultiplier) 
    {
        uint256 maxMultiplier = _getMaxLeverageMultiplier();
        
        // Apply safety buffer
        practicalMaxMultiplier = (maxMultiplier * (BASIS_POINTS - safetyBufferBps)) / BASIS_POINTS;
    }
    
    /**
     * @notice Calculate flash loan amount needed for target leverage
     * @param initialYieldTokens Amount of yield tokens user starts with
     * @param targetMultiplier Target leverage multiplier (e.g., 5e18 for 5x)
     * @return flashLoanAmount Amount of underlying tokens needed for flash loan
     * @return totalYieldTokensNeeded Total yield tokens after leverage
     * @return debtAmount Amount of debt tokens to mint
     */
    function calculateFlashLoanForLeverage(
        uint256 initialYieldTokens,
        uint256 targetMultiplier
    ) external view returns (
        uint256 flashLoanAmount,
        uint256 totalYieldTokensNeeded,
        uint256 debtAmount
    ) {
        if (initialYieldTokens == 0) revert InvalidAmount();
        if (targetMultiplier < PRECISION) revert InvalidMultiplier();
        
        // Check if target multiplier is achievable
        uint256 maxMultiplier = _getMaxLeverageMultiplier();
        if (targetMultiplier > maxMultiplier) revert ExceedsMaxLeverage();
        
        // Calculate total yield tokens needed for target leverage
        totalYieldTokensNeeded = (initialYieldTokens * targetMultiplier) / PRECISION;
        
        // Additional yield tokens needed from flash loan
        uint256 additionalYieldTokensNeeded = totalYieldTokensNeeded - initialYieldTokens;
        
        // Convert to underlying tokens for flash loan
        flashLoanAmount = alchemist.convertYieldTokensToUnderlying(additionalYieldTokensNeeded);
        
        // Calculate debt amount to mint (based on minimum collateralization)
        uint256 minCollateralization = alchemist.minimumCollateralization();
        uint256 maxDebtValue = (alchemist.convertYieldTokensToDebt(totalYieldTokensNeeded) * PRECISION) / minCollateralization;
        
        debtAmount = maxDebtValue;
    }
    
    /**
     * @notice Calculate leverage parameters with slippage protection
     * @param initialYieldTokens Initial yield token amount
     * @param targetMultiplier Target leverage multiplier
     * @param slippageBps Maximum slippage in basis points
     * @return params Leverage parameters struct
     */
    function calculateLeverageWithSlippage(
        uint256 initialYieldTokens,
        uint256 targetMultiplier,
        uint256 slippageBps
    ) external view returns (LeverageParams memory params) {
        
        (uint256 flashLoanAmount, uint256 totalYieldTokens, uint256 debtAmount) = 
            this.calculateFlashLoanForLeverage(initialYieldTokens, targetMultiplier);
        
        // Apply slippage protection
        params = LeverageParams({
            initialYieldTokens: initialYieldTokens,
            flashLoanAmount: flashLoanAmount,
            totalYieldTokensNeeded: totalYieldTokens,
            minYieldTokensFromSwap: _applySlippage(totalYieldTokens - initialYieldTokens, slippageBps, false),
            debtToMint: debtAmount,
            minUnderlyingFromDebtSwap: _applySlippage(
                alchemist.normalizeDebtTokensToUnderlying(debtAmount), 
                slippageBps, 
                false
            ),
            targetMultiplier: targetMultiplier,
            actualMultiplier: (totalYieldTokens * PRECISION) / initialYieldTokens,
            collateralizationRatio: (alchemist.convertYieldTokensToDebt(totalYieldTokens) * PRECISION) / debtAmount
        });
        
        // Validate that flash loan can be repaid
        require(
            params.minUnderlyingFromDebtSwap >= flashLoanAmount,
            "Cannot repay flash loan"
        );
    }
    
    /**
     * @notice Calculate deleveraging parameters
     * @param currentYieldTokens Current collateral amount
     * @param currentDebt Current debt amount
     * @param targetMultiplier Target leverage multiplier to achieve
     * @param slippageBps Slippage protection in basis points
     * @return params Deleveraging parameters
     */
    function calculateDeleveraging(
        uint256 currentYieldTokens,
        uint256 currentDebt,
        uint256 targetMultiplier,
        uint256 slippageBps
    ) external view returns (DeleverageParams memory params) {
        
        if (targetMultiplier < PRECISION) revert InvalidMultiplier();
        
        // Calculate current multiplier
        uint256 currentCollateralValue = alchemist.convertYieldTokensToDebt(currentYieldTokens);
        uint256 currentMultiplier = currentDebt == 0 ? PRECISION : 
            (currentCollateralValue * PRECISION) / (currentCollateralValue - currentDebt);
        
        // Target multiplier should be less than current for deleveraging
        if (targetMultiplier >= currentMultiplier) {
            // No deleveraging needed
            params = DeleverageParams({
                currentYieldTokens: currentYieldTokens,
                currentDebt: currentDebt,
                targetDebt: currentDebt,
                debtToRepay: 0,
                yieldTokensToWithdraw: 0,
                minUnderlyingFromYieldSwap: 0,
                flashLoanAmountForRepayment: 0,
                targetMultiplier: targetMultiplier
            });
            return params;
        }
        
        // Calculate target debt for desired multiplier
        // targetMultiplier = collateralValue / (collateralValue - targetDebt)
        // targetDebt = collateralValue - (collateralValue / targetMultiplier)
        uint256 targetDebt = currentCollateralValue - (currentCollateralValue * PRECISION) / targetMultiplier;
        uint256 debtToRepay = currentDebt > targetDebt ? currentDebt - targetDebt : 0;
        
        // Calculate yield tokens to withdraw for repayment
        uint256 yieldTokensToWithdraw = alchemist.convertDebtTokensToYield(debtToRepay);
        
        params = DeleverageParams({
            currentYieldTokens: currentYieldTokens,
            currentDebt: currentDebt,
            targetDebt: targetDebt,
            debtToRepay: debtToRepay,
            yieldTokensToWithdraw: yieldTokensToWithdraw,
            minUnderlyingFromYieldSwap: _applySlippage(
                alchemist.convertYieldTokensToUnderlying(yieldTokensToWithdraw),
                slippageBps,
                false
            ),
            flashLoanAmountForRepayment: alchemist.normalizeDebtTokensToUnderlying(debtToRepay),
            targetMultiplier: targetMultiplier
        });
    }
    
    /**
     * @notice Calculate optimal leverage for given risk parameters
     * @param initialAmount Initial yield token amount
     * @param riskToleranceBps Risk tolerance in basis points (higher = more aggressive)
     * @param maxGasCostEth Maximum acceptable gas cost in ETH
     * @param baseApyBps Base yield APY in basis points (caller-supplied)
     * @return optimalMultiplier Recommended leverage multiplier
     * @return estimatedApy Estimated APY with leverage
     */
    function calculateOptimalLeverage(
        uint256 initialAmount,
        uint256 riskToleranceBps,
        uint256 maxGasCostEth,
        uint256 baseApyBps
    ) external view returns (
        uint256 optimalMultiplier,
        uint256 estimatedApy
    ) {
        if (initialAmount == 0 || baseApyBps == 0) revert InvalidAmount();

        // Get practical max leverage with safety buffer
        uint256 safetyBuffer = BASIS_POINTS - riskToleranceBps;
        uint256 maxSafeMultiplier = _getPracticalMaxLeverageMultiplier(safetyBuffer);
        
        // Use 70% of max safe leverage as a conservative default
        optimalMultiplier = (maxSafeMultiplier * 7000) / BASIS_POINTS;
        
        // Estimate APY from caller-supplied base APY and leverage multiplier
        uint256 grossApy = (baseApyBps * optimalMultiplier) / PRECISION;
        uint256 underlyingValue = alchemist.convertYieldTokensToUnderlying(initialAmount);
        if (underlyingValue == 0) revert InvalidAmount();
        uint256 gasCostBps = (maxGasCostEth * BASIS_POINTS) / underlyingValue;
        estimatedApy = grossApy > gasCostBps ? grossApy - gasCostBps : 0;
        
        // Ensure minimum leverage of 1x
        if (optimalMultiplier < PRECISION) {
            optimalMultiplier = PRECISION;
        }
    }
    
    /**
     * @notice Get current position leverage multiplier
     * @param collateralAmount Current collateral amount
     * @param debtAmount Current debt amount  
     * @return currentMultiplier Current leverage multiplier
     * @return isHealthy Whether position is healthy
     */
    function getCurrentLeverage(
        uint256 collateralAmount,
        uint256 debtAmount
    ) external view returns (
        uint256 currentMultiplier,
        bool isHealthy
    ) {
        if (collateralAmount == 0) {
            return (0, true);
        }
        
        if (debtAmount == 0) {
            return (PRECISION, true); // 1x leverage, no debt
        }
        
        // Calculate effective multiplier
        uint256 collateralValue = alchemist.convertYieldTokensToDebt(collateralAmount);
        currentMultiplier = (collateralValue * PRECISION) / (collateralValue - debtAmount);
        
        // Check health
        uint256 collateralizationRatio = (collateralValue * PRECISION) / debtAmount;
        uint256 minCollateralization = alchemist.minimumCollateralization();
        isHealthy = collateralizationRatio >= minCollateralization;
    }
    
    /**
     * @notice Internal function to calculate maximum theoretical leverage multiplier
     */
    function _getMaxLeverageMultiplier() internal view returns (uint256 maxMultiplier) {
        uint256 minCollateralization = alchemist.minimumCollateralization();
        
        // Max leverage = 1 / (1 - LTV)
        // LTV = 1 - (1 / minCollateralization)
        // Max leverage = minCollateralization / (minCollateralization - 1e18)
        
        if (minCollateralization <= PRECISION) {
            revert InsufficientCollateralization();
        }
        
        maxMultiplier = (minCollateralization * PRECISION) / (minCollateralization - PRECISION);
    }
    
    /**
     * @notice Internal function to calculate practical maximum leverage
     */
    function _getPracticalMaxLeverageMultiplier(uint256 safetyBufferBps) internal view returns (uint256) {
        uint256 maxMultiplier = _getMaxLeverageMultiplier();
        return (maxMultiplier * (BASIS_POINTS - safetyBufferBps)) / BASIS_POINTS;
    }
    
    /**
     * @notice Apply slippage to an amount
     * @param amount Original amount
     * @param slippageBps Slippage in basis points
     * @param isPositive Whether slippage should be added (true) or subtracted (false)
     * @return adjustedAmount Amount after applying slippage
     */
    function _applySlippage(
        uint256 amount,
        uint256 slippageBps,
        bool isPositive
    ) internal pure returns (uint256 adjustedAmount) {
        uint256 slippageAmount = (amount * slippageBps) / BASIS_POINTS;
        
        if (isPositive) {
            adjustedAmount = amount + slippageAmount;
        } else {
            adjustedAmount = amount - slippageAmount;
        }
    }
}

/**
 * @notice Struct containing leverage calculation parameters
 */
struct LeverageParams {
    uint256 initialYieldTokens;      // Starting yield token amount
    uint256 flashLoanAmount;         // Underlying tokens to flash loan
    uint256 totalYieldTokensNeeded;  // Total yield tokens after leverage
    uint256 minYieldTokensFromSwap;  // Min yield tokens from underlying swap (slippage protected)
    uint256 debtToMint;              // Debt tokens to mint
    uint256 minUnderlyingFromDebtSwap; // Min underlying from debt token swap (slippage protected)
    uint256 targetMultiplier;        // Target leverage multiplier
    uint256 actualMultiplier;        // Actual achieved multiplier
    uint256 collateralizationRatio;  // Final collateralization ratio
}

/**
 * @notice Struct containing deleveraging calculation parameters
 */
struct DeleverageParams {
    uint256 currentYieldTokens;      // Current collateral amount
    uint256 currentDebt;             // Current debt amount
    uint256 targetDebt;              // Target debt amount
    uint256 debtToRepay;             // Amount of debt to repay
    uint256 yieldTokensToWithdraw;   // Yield tokens to withdraw for repayment
    uint256 minUnderlyingFromYieldSwap; // Min underlying from yield token swap
    uint256 flashLoanAmountForRepayment; // Flash loan amount needed for repayment
    uint256 targetMultiplier;        // Target leverage multiplier
}