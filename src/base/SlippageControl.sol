// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title SlippageControl
 * @notice Abstract contract providing standardized slippage handling
 * @dev Inherit from this contract to add consistent slippage protection to swappers and converters
 */
abstract contract SlippageControl {
    // ============ Constants ============

    /// @notice Maximum allowed slippage (5%)
    uint256 public constant MAX_SLIPPAGE = 500;

    /// @notice Precision for slippage calculations (basis points)
    uint256 public constant SLIPPAGE_PRECISION = 10_000;

    // ============ State ============

    /// @notice Current slippage tolerance in basis points (e.g., 100 = 1%)
    uint256 public slippageTolerance;

    // ============ Events ============

    /// @notice Emitted when slippage tolerance is updated
    event SlippageToleranceUpdated(uint256 oldTolerance, uint256 newTolerance);

    // ============ Errors ============

    /// @notice Thrown when attempting to set slippage higher than MAX_SLIPPAGE
    error SlippageTooHigh();

    /// @notice Thrown when actual output is less than minimum expected
    error SlippageExceeded();

    // ============ Constructor ============

    /**
     * @notice Initialize with a default slippage tolerance
     * @param _initialTolerance Initial slippage tolerance in basis points
     */
    constructor(uint256 _initialTolerance) {
        _setSlippageTolerance(_initialTolerance);
    }

    // ============ Internal Functions ============

    /**
     * @notice Apply slippage tolerance to calculate minimum acceptable output
     * @param amount The expected output amount
     * @return The minimum acceptable output after slippage
     */
    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (SLIPPAGE_PRECISION - slippageTolerance)) / SLIPPAGE_PRECISION;
    }

    /**
     * @notice Set the slippage tolerance
     * @param _tolerance New tolerance in basis points
     */
    function _setSlippageTolerance(uint256 _tolerance) internal {
        if (_tolerance > MAX_SLIPPAGE) revert SlippageTooHigh();

        uint256 oldTolerance = slippageTolerance;
        slippageTolerance = _tolerance;

        emit SlippageToleranceUpdated(oldTolerance, _tolerance);
    }

    /**
     * @notice Validate that output meets minimum requirements
     * @param actualOutput The actual output received
     * @param minOutput The minimum acceptable output
     */
    function _validateSlippage(uint256 actualOutput, uint256 minOutput) internal pure {
        if (actualOutput < minOutput) revert SlippageExceeded();
    }

    // ============ View Functions ============

    /**
     * @notice Get the current slippage tolerance
     * @return tolerance The current slippage tolerance in basis points
     */
    function getSlippageTolerance() external view returns (uint256 tolerance) {
        return slippageTolerance;
    }

    /**
     * @notice Calculate minimum output for a given expected amount
     * @param expectedAmount The expected output amount
     * @return minOutput The minimum acceptable output after slippage
     */
    function calculateMinOutput(uint256 expectedAmount) external view returns (uint256 minOutput) {
        return _applySlippage(expectedAmount);
    }
}
