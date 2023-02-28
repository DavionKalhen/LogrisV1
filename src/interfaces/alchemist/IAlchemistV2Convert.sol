pragma solidity ^0.8.0;

interface IAlchemistV2Convert {
    function convertYieldTokensToShares(address yieldToken, uint256 amount) external view returns (uint256);
    function convertSharesToYieldTokens(address yieldToken, uint256 shares) external view returns (uint256);
    function convertSharesToUnderlyingTokens(address yieldToken, uint256 shares) external view returns (uint256);
    function convertYieldTokensToUnderlying(address yieldToken, uint256 amount) external view returns (uint256);
    function convertUnderlyingTokensToYield(address yieldToken, uint256 amount) external view returns (uint256);
    function convertUnderlyingTokensToShares(address yieldToken, uint256 amount) external view returns (uint256);
    function normalizeUnderlyingTokensToDebt(address underlyingToken, uint256 amount) external view returns (uint256);
    function normalizeDebtTokensToUnderlying(address underlyingToken, uint256 amount) external view returns (uint256);
}