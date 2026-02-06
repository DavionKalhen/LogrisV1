// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IFlashLoanAdapter
 * @notice Unified interface for flash loan providers (Balancer, Euler, Aave, etc.)
 * @dev Abstracts different flash loan protocols behind a common interface
 */
interface IFlashLoanAdapter {
    // Events
    event FlashLoanExecuted(
        address indexed token,
        uint256 amount,
        uint256 fee,
        address indexed recipient
    );

    // Errors
    error UnsupportedToken();
    error FlashLoanFailed();
    error InsufficientRepayment();
    error InvalidRecipient();
    error InvalidAmount();
    error ReentrantCall();

    /**
     * @notice Execute a flash loan
     * @param token The token to borrow
     * @param amount The amount to borrow
     * @param recipient The contract that will receive the loan and handle the callback
     * @param data Arbitrary data to pass to the callback
     */
    function flashLoan(
        address token,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external;

    /**
     * @notice Get the flash loan fee for a given token and amount
     * @param token The token to borrow
     * @param amount The amount to borrow
     * @return fee The fee amount that will be charged
     */
    function getFlashLoanFee(address token, uint256 amount) external view returns (uint256 fee);

    /**
     * @notice Check if a token is supported for flash loans
     * @param token The token address to check
     * @return supported Whether the token is supported
     */
    function isTokenSupported(address token) external view returns (bool supported);

    /**
     * @notice Get the maximum flash loan amount for a token
     * @param token The token address
     * @return maxAmount The maximum amount that can be borrowed
     */
    function maxFlashLoan(address token) external view returns (uint256 maxAmount);

    /**
     * @notice Get the underlying flash loan provider address
     * @return provider The provider contract address (e.g., Balancer Vault, Euler DToken)
     */
    function getProvider() external view returns (address provider);
}
