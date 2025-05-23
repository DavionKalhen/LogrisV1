// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IDebtTokenAdapter
 * @dev Interface for interactions with debt tokens
 */
interface IDebtTokenAdapter {
    /**
     * @notice Returns the position data for a given account and yield token
     * @param account The account to query
     * @param yieldToken The yield token address
     * @return shares The amount of shares the account has
     * @return lastAccruedWeight The last accrued weight for the account
     */
    function positions(address account, address yieldToken) external view returns (uint256 shares, uint256 lastAccruedWeight);
    
    /**
     * @notice Returns the account data for a given account
     * @param account The account to query
     * @return debt The debt balance of the account (negative means credit)
     * @return lastUpdate The last time the account was updated
     */
    function accounts(address account) external view returns (int256 debt, uint256 lastUpdate);
    
    /**
     * @notice Converts shares to underlying tokens
     * @param yieldToken The yield token address
     * @param shares The amount of shares to convert
     * @return amount The amount of underlying tokens
     */
    function convertSharesToUnderlyingTokens(address yieldToken, uint256 shares) external view returns (uint256 amount);
    
    /**
     * @notice Converts underlying tokens to shares
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to convert
     * @return shares The amount of shares
     */
    function convertUnderlyingTokensToShares(address yieldToken, uint256 amount) external view returns (uint256 shares);
    
    /**
     * @notice Converts debt tokens to underlying value
     * @param underlyingToken The underlying token address
     * @param amount The amount of debt tokens to convert
     * @return value The value in underlying tokens
     */
    function normalizeDebtTokensToUnderlying(address underlyingToken, uint256 amount) external view returns (uint256 value);
    
    /**
     * @notice Returns the minimum collateralization ratio
     * @return ratio The minimum collateralization ratio (scaled by 1e18)
     */
    function minimumCollateralization() external view returns (uint256 ratio);
    
    /**
     * @notice Returns the parameters for a yield token
     * @param yieldToken The yield token address
     * @return expectedValue The expected value of the yield token
     * @return maximumExpectedValue The maximum expected value
     * @return maximumLoss The maximum allowed loss
     * @return creditUnlockRate The credit unlock rate
     */
    function getYieldTokenParameters(address yieldToken) external view returns (
        uint256 expectedValue,
        uint256 maximumExpectedValue,
        uint256 maximumLoss,
        uint256 creditUnlockRate
    );
    
    /**
     * @notice Approves the mint of debt tokens
     * @param spender The address that can mint
     * @param amount The amount that can be minted
     */
    function approveMint(address spender, uint256 amount) external;
    
    /**
     * @notice Mints debt tokens to the recipient
     * @param amount The amount to mint
     * @param recipient The recipient of the tokens
     */
    function mint(uint256 amount, address recipient) external;
    
    /**
     * @notice Mints debt tokens from the sender to the recipient
     * @param sender The sender who is minting
     * @param amount The amount to mint
     * @param recipient The recipient of the tokens
     */
    function mintFrom(address sender, uint256 amount, address recipient) external;
    
    /**
     * @notice Deposits underlying tokens into the yield token vault
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The recipient of the shares
     * @param minimumAmountOut The minimum amount of shares to receive
     * @return shares The amount of shares received
     */
    function depositUnderlying(address yieldToken, uint256 amount, address recipient, uint256 minimumAmountOut) external returns (uint256 shares);
    
    /**
     * @notice Converts underlying tokens to yield tokens
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to convert
     * @return yieldAmount The amount of yield tokens
     */
    function convertUnderlyingTokensToYield(address yieldToken, uint256 amount) external view returns (uint256 yieldAmount);
    
    /**
     * @notice Converts yield tokens to underlying tokens
     * @param yieldToken The yield token address
     * @param amount The amount of yield tokens to convert
     * @return underlyingAmount The amount of underlying tokens
     */
    function convertYieldTokensToUnderlying(address yieldToken, uint256 amount) external view returns (uint256 underlyingAmount);
    
    /**
     * @notice Burns debt tokens
     * @param amount The amount to burn
     * @param recipient The recipient of the credit
     */
    function burn(uint256 amount, address recipient) external;
    
    /**
     * @notice Withdraws underlying tokens
     * @param owner The owner of the shares
     * @param yieldToken The yield token address
     * @param shares The amount of shares to withdraw
     * @param recipient The recipient of the underlying tokens
     * @param minimumAmountOut The minimum amount of underlying tokens to receive
     * @return amount The amount of underlying tokens withdrawn
     */
    function withdrawUnderlyingFrom(address owner, address yieldToken, uint256 shares, address recipient, uint256 minimumAmountOut) external returns (uint256 amount);
    
    /**
     * @notice Approves the withdrawal of shares
     * @param spender The address that can withdraw
     * @param yieldToken The yield token address
     * @param shares The amount of shares that can be withdrawn
     */
    function approveWithdraw(address spender, address yieldToken, uint256 shares) external;
} 