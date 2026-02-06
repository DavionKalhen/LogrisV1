// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./IERC4626.sol";

/**
 * @title ILeveragedVault
 * @notice Interface for leveraged vaults using AlchemistV3
 * @dev Supports both explicit parameter calls and atomic (computed) convenience functions
 */
interface ILeveragedVault is IERC4626 {
    // ============ Events ============

    event DepositUnderlying(address indexed sender, address indexed underlyingToken, uint256 amount);
    event WithdrawUnderlying(address indexed sender, address indexed underlyingToken, uint256 shares);
    event Leverage(address indexed yieldToken, uint256 depositAmount, int256 debtAmount);

    // ============ View Functions ============

    /// @notice Returns the yield token address (e.g., wstETH)
    function getYieldToken() external view returns (address yieldToken);

    /// @notice Returns the underlying token address (e.g., wstETH for wstETH vault)
    function getUnderlyingToken() external view returns (address underlyingToken);

    /// @notice Returns the amount of underlying tokens sitting in the vault (not yet leveraged)
    function getDepositPoolBalance() external view returns (uint256 amount);

    /// @notice Returns the vault's total deposited collateral in Alchemist
    function getVaultDepositedBalance() external view returns (uint256 amount);

    /// @notice Returns the vault's current debt balance in Alchemist
    function getVaultDebtBalance() external view returns (int256 amount);

    /// @notice Returns the vault's net redeemable balance (collateral - debt value)
    function getVaultRedeemableBalance() external view returns (uint256 amount);

    /// @notice Returns the remaining deposit capacity in Alchemist
    function getDepositCapacity() external view returns (uint256 amount);

    /// @notice Returns the remaining borrow capacity for the vault's position
    function getBorrowCapacity() external view returns (uint256 amount);

    /// @notice Returns shares that can be withdrawn without deleveraging
    function getFreeWithdrawCapacity() external view returns (uint256 shares);

    /// @notice Returns total shares that can be withdrawn (may require deleveraging)
    function getTotalWithdrawCapacity() external view returns (uint256 shares);

    /// @notice Converts underlying token amount to vault shares
    function convertUnderlyingTokensToShares(uint256 amount) external view returns (uint256 shares);

    /// @notice Converts vault shares to underlying token amount
    function convertSharesToUnderlyingTokens(uint256 shares) external view returns (uint256 amount);

    // ============ Parameter Calculation Functions ============

    /// @notice Calculate leverage parameters using vault's default slippage settings
    /// @param depositAmount Amount of underlying tokens to leverage
    function getLeverageParameters(uint256 depositAmount) external view returns (
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    );

    /// @notice Calculate all parameters needed for leverage operation
    /// @param depositAmount Amount of underlying tokens to leverage
    /// @param underlyingSlippageBasisPoints Slippage tolerance for underlying token operations (basis points)
    /// @param debtSlippageBasisPoints Slippage tolerance for debt token swap (basis points, includes peg deviation)
    /// @return clampedDeposit Actual deposit amount (clamped to available capacity)
    /// @return flashLoanAmount Amount of underlying to flash loan
    /// @return underlyingDepositMin Minimum yield tokens expected from deposit
    /// @return mintAmount Amount of debt tokens to mint
    /// @return debtTradeMin Minimum underlying tokens expected from debt swap
    function getLeverageParameters(
        uint256 depositAmount,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external view returns (
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    );

    /// @notice Calculate withdraw parameters using vault's default slippage settings
    /// @param shares Amount of vault shares to withdraw
    function getWithdrawUnderlyingParameters(uint256 shares) external view returns (
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    );

    /// @notice Calculate all parameters needed for withdraw/deleverage operation
    /// @param shares Amount of vault shares to withdraw
    /// @param underlyingSlippageBasisPoints Slippage tolerance for underlying token operations
    /// @param debtSlippageBasisPoints Slippage tolerance for debt token swap
    /// @return flashLoanAmount Amount to flash loan for deleveraging
    /// @return burnAmount Amount of debt tokens to burn
    /// @return minUnderlyingOut Minimum underlying tokens to receive
    function getWithdrawUnderlyingParameters(
        uint256 shares,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external view returns (
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    );

    // ============ User Deposit Functions ============

    /// @notice Deposit underlying tokens into the vault
    /// @param amount Amount of underlying tokens to deposit
    /// @return shares Amount of vault shares minted to caller
    function depositUnderlying(uint256 amount) external returns (uint256 shares);

    /// @notice Deposit ETH into the vault (wraps to WETH)
    /// @return shares Amount of vault shares minted to caller
    function depositUnderlying() external payable returns (uint256 shares);

    // ============ Leverage Functions ============

    /// @notice Execute leverage with explicit parameters
    /// @dev Parameters should be obtained from getLeverageParameters()
    /// @param clampedDeposit Amount of underlying to deposit from pool
    /// @param flashLoanAmount Amount to flash loan
    /// @param underlyingDepositMin Minimum yield tokens from deposit (slippage protection)
    /// @param mintAmount Amount of debt tokens to mint
    /// @param debtTradeMin Minimum underlying from debt swap (slippage protection)
    function leverage(
        uint256 clampedDeposit,
        uint256 flashLoanAmount,
        uint256 underlyingDepositMin,
        uint256 mintAmount,
        uint256 debtTradeMin
    ) external;

    /// @notice Execute leverage with auto-computed parameters
    /// @dev Convenience function that computes parameters internally
    /// @param depositAmount Amount of underlying to leverage
    /// @param underlyingSlippageBasisPoints Slippage tolerance for underlying operations
    /// @param debtSlippageBasisPoints Slippage tolerance for debt swap
    function leverageAtomic(
        uint256 depositAmount,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external;

    // ============ Withdraw Functions ============

    /// @notice Withdraw underlying tokens with explicit parameters
    /// @dev Parameters should be obtained from getWithdrawUnderlyingParameters()
    /// @param shares Amount of vault shares to burn
    /// @param flashLoanAmount Amount to flash loan for deleveraging
    /// @param burnAmount Amount of debt to burn
    /// @param minUnderlyingOut Minimum underlying to receive (slippage protection)
    /// @return underlyingAmount Amount of underlying tokens withdrawn
    function withdrawUnderlying(
        uint256 shares,
        uint256 flashLoanAmount,
        uint256 burnAmount,
        uint256 minUnderlyingOut
    ) external returns (uint256 underlyingAmount);

    /// @notice Withdraw underlying tokens with auto-computed parameters
    /// @dev Convenience function that computes parameters internally
    /// @param shares Amount of vault shares to withdraw
    /// @param underlyingSlippageBasisPoints Slippage tolerance for underlying operations
    /// @param debtSlippageBasisPoints Slippage tolerance for debt swap
    /// @return underlyingAmount Amount of underlying tokens withdrawn
    function withdrawUnderlyingAtomic(
        uint256 shares,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints
    ) external returns (uint256 underlyingAmount);
}
