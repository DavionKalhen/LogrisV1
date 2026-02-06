// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ILeveragedVaultCallback
 * @notice Interface for leverager to interact with vault's AlchemistV3 position
 */
interface ILeveragedVaultCallback {
    
    // Events
    event VaultPositionCreated(uint256 indexed positionId);
    event VaultLeverageExecuted(address indexed user, uint256 leverageGained, uint256 sharesMinted);
    event VaultDeleverageExecuted(address indexed user, uint256 leverageLost, uint256 sharesBurned);
    
    /**
     * @notice Deposit yield tokens to vault's AlchemistV3 position
     * @param amount Amount of yield tokens to deposit
     * @return sharesAdded Amount of shares added to position
     */
    function vaultDepositYieldTokens(uint256 amount) external returns (uint256 sharesAdded);
    
    /**
     * @notice Mint debt tokens from vault's AlchemistV3 position
     * @param amount Amount of debt tokens to mint
     * @param recipient Address to receive the debt tokens
     */
    function vaultMintDebtTokens(uint256 amount, address recipient) external;
    
    /**
     * @notice Withdraw yield tokens from vault's AlchemistV3 position
     * @param amount Amount of yield tokens to withdraw
     * @param recipient Address to receive the yield tokens
     * @return actualWithdrawn Actual amount withdrawn
     */
    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external returns (uint256 actualWithdrawn);
    
    /**
     * @notice Burn debt tokens against vault's AlchemistV3 position
     * @param amount Amount of debt tokens to burn
     */
    function vaultBurnDebtTokens(uint256 amount) external;
    
    /**
     * @notice Get vault's position ID
     * @return positionId The vault's AlchemistV3 position ID
     */
    function getVaultPositionId() external view returns (uint256 positionId);

} 