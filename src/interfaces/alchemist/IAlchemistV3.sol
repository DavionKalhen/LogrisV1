// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IAlchemistV3 {
    struct Account {
        uint256 debt;
        uint256 collateral;
        uint256 lastAccruedWeight;
    }
    
    struct Position {
        address owner;
        uint256 debt;
        uint256 collateral;
        uint256 lastAccruedWeight;
    }

    // Core functions needed for our testing
    function alchemistPositionNFT() external view returns (address);
    function underlyingToken() external view returns (address);
    function yieldToken() external view returns (address);
    function debtToken() external view returns (address);
    function minimumCollateralization() external view returns (uint256);
    
    function createPosition(address owner) external returns (uint256);

    // Core AlchemistV3 functions with correct signatures
    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256);
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256);
    function mint(uint256 tokenId, uint256 amount, address recipient) external;
    function burn(uint256 amount, uint256 recipientId) external returns (uint256);

    // Legacy signatures (kept for compatibility)
    function depositUnderlying(uint256 positionId, uint256 amount, address recipient, uint256 minimumAmountOut) external returns (uint256);
    function withdrawUnderlying(uint256 positionId, uint256 yieldTokenAmount, address recipient, uint256 minimumAmountOut) external returns (uint256);
    function liquidate(uint256 positionId, uint256 yieldTokenAmount, uint256 minimumAmountOut) external returns (uint256);

    function getAccount(uint256 positionId) external view returns (Account memory);
    function getPosition(uint256 positionId) external view returns (Position memory);

    // CDP query function
    function getCDP(uint256 tokenId) external view returns (uint256 collateral, uint256 debt, uint256 earmarked);
    function getTotalDeposited() external view returns (uint256);

    // Utility functions
    function getUnderlyingTokensPerShare() external view returns (uint256);
    function getYieldTokensPerShare() external view returns (uint256);
    function calculateUnderlyingTokensForShares(uint256 shares, uint256 totalShares) external view returns (uint256);
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view returns (uint256);
    function normalizeDebtTokensToUnderlying(uint256 amount) external view returns (uint256);
    
    // State functions
    function version() external view returns (string memory);
    function admin() external view returns (address);
    function pendingAdmin() external view returns (address);
    function alchemistFeeVault() external view returns (address);
    function transmuter() external view returns (address);
    function tokenAdapter() external view returns (address);
    function protocolFeeReceiver() external view returns (address);
    function underlyingConversionFactor() external view returns (uint256);
    function blocksPerYear() external view returns (uint256);
    function cumulativeEarmarked() external view returns (uint256);
    function depositCap() external view returns (uint256);
    function lastEarmarkBlock() external view returns (uint256);
    function lastRedemptionBlock() external view returns (uint256);
    function collateralizationLowerBound() external view returns (uint256);
    function globalMinimumCollateralization() external view returns (uint256);
    function totalDebt() external view returns (uint256);
    function totalSyntheticsIssued() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function liquidatorFee() external view returns (uint256);
    function depositsPaused() external view returns (bool);
    function loansPaused() external view returns (bool);
    function guardians(address) external view returns (bool);
} 