// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ITokenConverter
/// @notice Converts between underlying and yield tokens for leverage operations
/// @dev Each converter handles one specific underlying↔yield token pair
interface ITokenConverter {
    /// @notice Convert underlying to yield token (e.g., WETH → wstETH)
    /// @param amount Amount of underlying tokens to convert
    /// @param recipient Address to receive the yield tokens
    /// @param minYieldOut Minimum yield tokens expected from conversion
    /// @return yieldAmount Amount of yield tokens received
    function toYield(
        uint256 amount,
        address recipient,
        uint256 minYieldOut
    ) external returns (uint256 yieldAmount);

    /// @notice Convert yield token to underlying (e.g., wstETH → WETH)
    /// @param amount Amount of yield tokens to convert
    /// @param recipient Address to receive the underlying tokens
    /// @param minUnderlyingOut Minimum underlying expected from conversion
    /// @return underlyingAmount Amount of underlying tokens received
    function toUnderlying(
        uint256 amount,
        address recipient,
        uint256 minUnderlyingOut
    ) external returns (uint256 underlyingAmount);

    /// @notice The yield token this converter handles
    function yieldToken() external view returns (address);

    /// @notice The underlying token this converter handles
    function underlyingToken() external view returns (address);

    /// @notice Preview how many yield tokens would be received
    /// @param amount Amount of underlying tokens
    /// @return Expected yield tokens (may differ from actual due to slippage)
    function previewToYield(uint256 amount) external view returns (uint256);

    /// @notice Preview how many underlying tokens would be received
    /// @param amount Amount of yield tokens
    /// @return Expected underlying tokens (may differ from actual due to slippage)
    function previewToUnderlying(uint256 amount) external view returns (uint256);
}
