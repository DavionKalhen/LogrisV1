// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IDebtTokenAdapter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title SimpleDebtTokenAdapter
 * @dev A simple implementation of IDebtTokenAdapter that can be used for testing
 */
contract SimpleDebtTokenAdapter is IDebtTokenAdapter, Ownable {
    mapping(address => mapping(address => uint256)) private _shares; // account => yieldToken => shares
    mapping(address => int256) private _debts; // account => debt
    mapping(address => uint256) private _lastUpdated; // account => lastUpdated
    
    // Yield token parameters
    struct YieldTokenParams {
        uint256 expectedValue;
        uint256 maximumExpectedValue;
        uint256 maximumLoss;
        uint256 creditUnlockRate;
    }
    
    mapping(address => YieldTokenParams) private _yieldTokenParams;
    mapping(address => mapping(address => uint256)) private _approvedMints; // account => spender => amount
    mapping(address => mapping(address => mapping(address => uint256))) private _approvedWithdraws; // account => spender => yieldToken => shares
    
    uint256 private _minimumCollateralization;
    mapping(address => mapping(address => uint256)) private _conversionRates; // yieldToken => underlyingToken => rate
    
    address private _debtToken;
    
    constructor(address debtToken, uint256 minimumCollateralization_) Ownable(msg.sender) {
        _debtToken = debtToken;
        _minimumCollateralization = minimumCollateralization_;
    }
    
    /**
     * @notice Add a supported yield token
     * @param yieldToken The yield token address
     * @param expectedValue Current expected value in underlying tokens
     * @param maximumExpectedValue Maximum expected value in underlying tokens
     * @param maximumLoss Maximum allowed loss
     * @param creditUnlockRate Credit unlock rate
     */
    function addYieldToken(
        address yieldToken,
        uint256 expectedValue,
        uint256 maximumExpectedValue,
        uint256 maximumLoss,
        uint256 creditUnlockRate
    ) external onlyOwner {
        _yieldTokenParams[yieldToken] = YieldTokenParams({
            expectedValue: expectedValue,
            maximumExpectedValue: maximumExpectedValue,
            maximumLoss: maximumLoss,
            creditUnlockRate: creditUnlockRate
        });
    }
    
    /**
     * @notice Set conversion rate between yield token and underlying token
     * @param yieldToken The yield token address
     * @param underlyingToken The underlying token address
     * @param rate The conversion rate (scaled by 1e18)
     */
    function setConversionRate(address yieldToken, address underlyingToken, uint256 rate) external onlyOwner {
        _conversionRates[yieldToken][underlyingToken] = rate;
    }
    
    // IDebtTokenAdapter interface implementation
    
    function positions(address account, address yieldToken) external view returns (uint256 shares, uint256 lastAccruedWeight) {
        return (_shares[account][yieldToken], 0); // lastAccruedWeight is not used in this simple implementation
    }
    
    function accounts(address account) external view returns (int256 debt, uint256 lastUpdate) {
        return (_debts[account], _lastUpdated[account]);
    }
    
    function convertSharesToUnderlyingTokens(address yieldToken, uint256 shares) external view returns (uint256 amount) {
        // In this simple implementation, we use a 1:1 conversion rate
        return shares;
    }
    
    function convertUnderlyingTokensToShares(address yieldToken, uint256 amount) external view returns (uint256 shares) {
        // In this simple implementation, we use a 1:1 conversion rate
        return amount;
    }
    
    function normalizeDebtTokensToUnderlying(address underlyingToken, uint256 amount) external view returns (uint256 value) {
        // In this simple implementation, we use a 1:1 conversion rate
        return amount;
    }
    
    function minimumCollateralization() external view returns (uint256 ratio) {
        return _minimumCollateralization;
    }
    
    function getYieldTokenParameters(address yieldToken) external view returns (
        uint256 expectedValue,
        uint256 maximumExpectedValue,
        uint256 maximumLoss,
        uint256 creditUnlockRate
    ) {
        YieldTokenParams memory params = _yieldTokenParams[yieldToken];
        return (
            params.expectedValue,
            params.maximumExpectedValue,
            params.maximumLoss,
            params.creditUnlockRate
        );
    }
    
    function approveMint(address spender, uint256 amount) external {
        _approvedMints[msg.sender][spender] = amount;
    }
    
    function mint(uint256 amount, address recipient) external {
        // Mint debt tokens to recipient
        _debts[recipient] += int256(amount);
        _lastUpdated[recipient] = block.timestamp;
        
        // In a real implementation, we would transfer debt tokens
        // IERC20(_debtToken).transfer(recipient, amount);
    }
    
    function mintFrom(address sender, uint256 amount, address recipient) external {
        require(_approvedMints[sender][msg.sender] >= amount, "Not approved to mint");
        _approvedMints[sender][msg.sender] -= amount;
        
        // Mint debt tokens to recipient
        _debts[sender] += int256(amount);
        _lastUpdated[sender] = block.timestamp;
        
        // In a real implementation, we would transfer debt tokens
        // IERC20(_debtToken).transfer(recipient, amount);
    }
    
    function depositUnderlying(address yieldToken, uint256 amount, address recipient, uint256 minimumAmountOut) external returns (uint256 shares) {
        require(_conversionRates[yieldToken][address(0)] > 0, "Yield token not supported");
        require(amount >= minimumAmountOut, "Amount less than minimum");
        
        // Transfer underlying tokens from sender to adapter
        // IERC20(underlyingToken).transferFrom(msg.sender, address(this), amount);
        
        // Credit shares to recipient
        _shares[recipient][yieldToken] += amount;
        
        // Update yield token expected value
        _yieldTokenParams[yieldToken].expectedValue += amount;
        
        return amount;
    }
    
    function convertUnderlyingTokensToYield(address yieldToken, uint256 amount) external view returns (uint256 yieldAmount) {
        // In this simple implementation, we use a 1:1 conversion rate
        return amount;
    }
    
    function convertYieldTokensToUnderlying(address yieldToken, uint256 amount) external view returns (uint256 underlyingAmount) {
        // In this simple implementation, we use a 1:1 conversion rate
        return amount;
    }
    
    function burn(uint256 amount, address recipient) external {
        // Burn debt tokens from sender
        _debts[recipient] -= int256(amount);
        _lastUpdated[recipient] = block.timestamp;
        
        // In a real implementation, we would transfer debt tokens from sender
        // IERC20(_debtToken).transferFrom(msg.sender, address(this), amount);
    }
    
    function withdrawUnderlyingFrom(address owner, address yieldToken, uint256 shares, address recipient, uint256 minimumAmountOut) external returns (uint256 amount) {
        require(_shares[owner][yieldToken] >= shares, "Not enough shares");
        
        // If msg.sender is not the owner, check if they are approved
        if (msg.sender != owner) {
            require(_approvedWithdraws[owner][msg.sender][yieldToken] >= shares, "Not approved to withdraw");
            _approvedWithdraws[owner][msg.sender][yieldToken] -= shares;
        }
        
        // Debit shares from owner
        _shares[owner][yieldToken] -= shares;
        
        // Update yield token expected value
        _yieldTokenParams[yieldToken].expectedValue -= shares;
        
        // In a real implementation, we would transfer underlying tokens to recipient
        // IERC20(underlyingToken).transfer(recipient, shares);
        
        return shares; // In this simple implementation, 1 share = 1 underlying token
    }
    
    function approveWithdraw(address spender, address yieldToken, uint256 shares) external {
        _approvedWithdraws[msg.sender][spender][yieldToken] = shares;
    }
} 