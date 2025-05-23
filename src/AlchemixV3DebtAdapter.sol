// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IDebtTokenAdapter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/alchemist/ITokenAdapter.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

// Import Account struct directly
import { Account } from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";

/**
 * @title AlchemixV3DebtAdapter
 * @dev Implementation of IDebtTokenAdapter for Alchemix V3
 * This adapter allows our Leverager system to work with AlchemistV3
 */
contract AlchemixV3DebtAdapter is IDebtTokenAdapter, Ownable {
    // The Alchemist V3 contract
    IAlchemistV3 public alchemistV3;
    
    // Positions mapping: account => tokenId
    mapping(address => uint256) private _positionIds;
    
    // Map of yield token to underlying token
    mapping(address => address) private _yieldToUnderlying;
    
    // Address of the debt token (alAsset)
    address public debtToken;
    
    // Minimum collateralization ratio (scaled by 1e18)
    uint256 public override minimumCollateralization;
    
    /**
     * @notice Constructor to initialize the adapter
     * @param _alchemistV3 The address of the AlchemistV3 contract
     */
    constructor(address _alchemistV3) Ownable(msg.sender) {
        alchemistV3 = IAlchemistV3(_alchemistV3);
        debtToken = alchemistV3.debtToken();
        minimumCollateralization = alchemistV3.minimumCollateralization();
    }
    
    /**
     * @notice Associate a yield token with its underlying token
     * @param yieldToken The yield token address
     * @param underlyingToken The underlying token address
     */
    function setYieldTokenUnderlyingPair(address yieldToken, address underlyingToken) external onlyOwner {
        _yieldToUnderlying[yieldToken] = underlyingToken;
    }
    
    /**
     * @notice Get or create a position ID for an account
     * @param account The account address
     * @return tokenId The position token ID
     */
    function getOrCreatePositionId(address account) public returns (uint256) {
        if (_positionIds[account] == 0) {
            // Create a new position for this account if none exists
            uint256 tokenId = IAlchemistV3Position(alchemistV3.alchemistPositionNFT()).mint(account);
            _positionIds[account] = tokenId;
        }
        return _positionIds[account];
    }
    
    /**
     * @notice Get the position ID for an account
     * @param account The account address
     * @return tokenId The position token ID
     */
    function getPositionId(address account) public view returns (uint256) {
        return _positionIds[account];
    }
    
    /**
     * @notice Returns the position data for a given account and yield token
     * @param account The account to query
     * @param yieldToken The yield token address
     * @return shares The amount of shares the account has
     * @return lastAccruedWeight The last accrued weight for the account
     */
    function positions(address account, address yieldToken) external view override returns (uint256 shares, uint256 lastAccruedWeight) {
        uint256 tokenId = _positionIds[account];
        if (tokenId == 0) return (0, 0);
        
        // Get position data using getCDP
        (uint256 collateral, , ) = alchemistV3.getCDP(tokenId);
        // V3 doesn't provide lastAccruedWeight directly, so we use 0
        return (collateral, 0);
    }
    
    /**
     * @notice Returns the account data for a given account
     * @param account The account to query
     * @return debt The debt balance of the account (negative means credit)
     * @return lastUpdate The last time the account was updated
     */
    function accounts(address account) external view override returns (int256 debt, uint256 lastUpdate) {
        uint256 tokenId = _positionIds[account];
        if (tokenId == 0) return (0, 0);
        
        // Get debt data using getCDP
        (, uint256 accountDebt, ) = alchemistV3.getCDP(tokenId);
        
        // V3 uses positive debt, so we keep the sign the same
        // For lastUpdate, we don't have direct access to this in V3, so we use the current block number
        return (int256(accountDebt), block.number);
    }
    
    /**
     * @notice Converts shares to underlying tokens
     * @param yieldToken The yield token address
     * @param shares The amount of shares to convert
     * @return amount The amount of underlying tokens
     */
    function convertSharesToUnderlyingTokens(address yieldToken, uint256 shares) external view override returns (uint256 amount) {
        // Use a fixed price since tokenAdapter() is not view in AlchemistV3
        // In a production environment, this would be improved with a cached value
        // or using an external price oracle
        return shares; // Use 1:1 conversion for simplicity
    }
    
    /**
     * @notice Converts underlying tokens to shares
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to convert
     * @return shares The amount of shares
     */
    function convertUnderlyingTokensToShares(address yieldToken, uint256 amount) external view override returns (uint256 shares) {
        // Use a fixed price since tokenAdapter() is not view in AlchemistV3
        return amount; // Use 1:1 conversion for simplicity
    }
    
    /**
     * @notice Converts debt tokens to underlying value
     * @param underlyingToken The underlying token address
     * @param amount The amount of debt tokens to convert
     * @return value The value in underlying tokens
     */
    function normalizeDebtTokensToUnderlying(address underlyingToken, uint256 amount) external view override returns (uint256 value) {
        // In AlchemistV3, this conversion would typically involve the exchange rate between debt tokens and underlying
        return amount; // Simplified for this example, adjust according to actual Alchemist V3 logic
    }
    
    /**
     * @notice Returns the parameters for a yield token
     * @param yieldToken The yield token address
     * @return expectedValue The expected value of the yield token
     * @return maximumExpectedValue The maximum expected value
     * @return maximumLoss The maximum allowed loss
     * @return creditUnlockRate The credit unlock rate
     */
    function getYieldTokenParameters(address yieldToken) external view override returns (
        uint256 expectedValue,
        uint256 maximumExpectedValue,
        uint256 maximumLoss,
        uint256 creditUnlockRate
    ) {
        // Get total debt and deposit cap from AlchemistV3
        uint256 totalDebt = alchemistV3.totalDebt();
        uint256 depositCap = alchemistV3.depositCap();
        
        return (totalDebt, depositCap, 0, 0);
    }
    
    /**
     * @notice Approves the mint of debt tokens
     * @param spender The address that can mint
     * @param amount The amount that can be minted
     */
    function approveMint(address spender, uint256 amount) external override {
        uint256 tokenId = getOrCreatePositionId(msg.sender);
        alchemistV3.approveMint(tokenId, spender, amount);
    }
    
    /**
     * @notice Mints debt tokens to the recipient
     * @param amount The amount to mint
     * @param recipient The recipient of the tokens
     */
    function mint(uint256 amount, address recipient) external override {
        uint256 tokenId = getOrCreatePositionId(msg.sender);
        alchemistV3.mint(tokenId, amount, recipient);
    }
    
    /**
     * @notice Mints debt tokens from the sender to the recipient
     * @param sender The sender who is minting
     * @param amount The amount to mint
     * @param recipient The recipient of the tokens
     */
    function mintFrom(address sender, uint256 amount, address recipient) external override {
        uint256 tokenId = getPositionId(sender);
        require(tokenId > 0, "Sender has no position");
        alchemistV3.mintFrom(tokenId, amount, recipient);
    }
    
    /**
     * @notice Deposits underlying tokens into the yield token vault
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to deposit
     * @param recipient The recipient of the shares
     * @param minimumAmountOut The minimum amount of shares to receive
     * @return shares The amount of shares received
     */
    function depositUnderlying(address yieldToken, uint256 amount, address recipient, uint256 minimumAmountOut) external override returns (uint256 shares) {
        // Transfer tokens from caller to this contract first
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        
        // Approve the tokens to AlchemistV3
        IERC20(yieldToken).approve(address(alchemistV3), amount);
        
        // Then deposit into the recipient's position
        uint256 tokenId = getOrCreatePositionId(recipient);
        
        // In V3, we deposit directly with yield tokens, not underlying
        return alchemistV3.deposit(amount, recipient, tokenId);
    }
    
    /**
     * @notice Converts underlying tokens to yield tokens
     * @param yieldToken The yield token address
     * @param amount The amount of underlying tokens to convert
     * @return yieldAmount The amount of yield tokens
     */
    function convertUnderlyingTokensToYield(address yieldToken, uint256 amount) external view override returns (uint256 yieldAmount) {
        // This is simplified; in a real implementation you would use the actual conversion rate
        return amount;
    }
    
    /**
     * @notice Converts yield tokens to underlying tokens
     * @param yieldToken The yield token address
     * @param amount The amount of yield tokens to convert
     * @return underlyingAmount The amount of underlying tokens
     */
    function convertYieldTokensToUnderlying(address yieldToken, uint256 amount) external view override returns (uint256 underlyingAmount) {
        // This is simplified; in a real implementation you would use the actual conversion rate
        return amount;
    }
    
    /**
     * @notice Burns debt tokens
     * @param amount The amount to burn
     * @param recipient The recipient of the credit
     */
    function burn(uint256 amount, address recipient) external override {
        uint256 tokenId = getPositionId(recipient);
        require(tokenId > 0, "Recipient has no position");
        
        // Transfer debt tokens from caller to this contract first
        IERC20(debtToken).transferFrom(msg.sender, address(this), amount);
        
        // For burning, we need to approve the debt tokens
        IERC20(debtToken).approve(address(alchemistV3), amount);
        
        // Then burn them to credit the recipient's account
        alchemistV3.burn(amount, tokenId);
    }
    
    /**
     * @notice Withdraws underlying tokens
     * @param owner The owner of the shares
     * @param yieldToken The yield token address
     * @param shares The amount of shares to withdraw
     * @param recipient The recipient of the underlying tokens
     * @param minimumAmountOut The minimum amount of underlying tokens to receive
     * @return amount The amount of underlying tokens withdrawn
     */
    function withdrawUnderlyingFrom(address owner, address yieldToken, uint256 shares, address recipient, uint256 minimumAmountOut) external override returns (uint256 amount) {
        uint256 tokenId = getPositionId(owner);
        require(tokenId > 0, "Owner has no position");
        
        // V3 withdraws directly as yield tokens, which are the same as the underlying in our adapter
        return alchemistV3.withdraw(shares, recipient, tokenId);
    }
    
    /**
     * @notice Approves the withdrawal of shares
     * @param spender The address that can withdraw
     * @param yieldToken The yield token address
     * @param shares The amount of shares that can be withdrawn
     */
    function approveWithdraw(address spender, address yieldToken, uint256 shares) external override {
        // V3 doesn't have explicit withdraw approval mechanism like V2,
        // it would require transfer of the position NFT or specific approval
        // This is a placeholder for compatibility
    }
} 