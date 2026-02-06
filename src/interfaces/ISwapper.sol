// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ISwapper
 * @notice Interface for token swapping functionality
 * @dev Provides abstraction for different DEX integrations (Curve, Uniswap, etc.)
 */
interface ISwapper {
    // Events
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );
    
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);
    event SwapFeeUpdated(uint256 oldFee, uint256 newFee);
    
    // Errors
    error InsufficientOutput();
    error InvalidTokenPair();
    error ExcessiveSlippage();
    error SwapFailed();
    error InvalidAmount();
    
    /**
     * @notice Swap debt tokens for underlying tokens
     * @param debtAmount Amount of debt tokens to swap
     * @param minUnderlyingOut Minimum amount of underlying tokens to receive
     * @param recipient Address to receive the underlying tokens
     * @param swapData Additional data for swap execution (route, deadline, etc.)
     * @return underlyingReceived Actual amount of underlying tokens received
     */
    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata swapData
    ) external returns (uint256 underlyingReceived);
    
    /**
     * @notice Swap underlying tokens for debt tokens
     * @param underlyingAmount Amount of underlying tokens to swap
     * @param minDebtOut Minimum amount of debt tokens to receive
     * @param recipient Address to receive the debt tokens
     * @param swapData Additional data for swap execution
     * @return debtReceived Actual amount of debt tokens received
     */
    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256 minDebtOut,
        address recipient,
        bytes calldata swapData
    ) external returns (uint256 debtReceived);
    
    /**
     * @notice Preview swap output for debt to underlying
     * @param debtAmount Amount of debt tokens to swap
     * @return expectedUnderlying Expected amount of underlying tokens
     * @return minimumOutput Minimum output considering slippage
     */
    function previewSwapDebtToUnderlying(uint256 debtAmount) 
        external view returns (uint256 expectedUnderlying, uint256 minimumOutput);
    
    /**
     * @notice Preview swap output for underlying to debt
     * @param underlyingAmount Amount of underlying tokens to swap
     * @return expectedDebt Expected amount of debt tokens
     * @return minimumOutput Minimum output considering slippage
     */
    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external view returns (uint256 expectedDebt, uint256 minimumOutput);
    
    /**
     * @notice Get current exchange rate from debt to underlying
     * @return rate Exchange rate scaled by 1e18
     */
    function getDebtToUnderlyingRate() external view returns (uint256 rate);
    
    /**
     * @notice Get current exchange rate from underlying to debt
     * @return rate Exchange rate scaled by 1e18
     */
    function getUnderlyingToDebtRate() external view returns (uint256 rate);
    
    /**
     * @notice Get swap fee in basis points
     * @return fee Swap fee (e.g., 30 = 0.3%)
     */
    function getSwapFee() external view returns (uint256 fee);
    
    /**
     * @notice Get slippage tolerance in basis points
     * @return tolerance Slippage tolerance (e.g., 100 = 1%)
     */
    function getSlippageTolerance() external view returns (uint256 tolerance);

    /**
     * @notice Check if a token pair is supported
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return supported Whether the pair is supported
     */
    function isSupportedPair(address tokenA, address tokenB) external view returns (bool supported);
} 