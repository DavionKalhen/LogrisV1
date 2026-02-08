// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ILeveragedVaultCallback
 * @notice Interface for leverager to interact with vault's AlchemistV3 position
 */
interface ILeveragedVaultCallback {
    
    // Events

    /// @notice Emitted when the vault creates its first Alchemist position.
    /// @param positionId The newly created position NFT ID.
    event VaultPositionCreated(uint256 indexed positionId);

    /// @notice Emitted when debt tokens are minted from the vault's Alchemist position.
    /// @param amount Amount of debt tokens minted.
    /// @param recipient Address that received the debt tokens.
    event VaultDebtMinted(uint256 amount, address indexed recipient);

    /// @notice Emitted when yield tokens are withdrawn from the vault's Alchemist position.
    /// @param amount Amount of yield tokens withdrawn.
    /// @param recipient Address that received the yield tokens.
    event VaultYieldWithdrawn(uint256 amount, address indexed recipient);

    /// @notice Emitted when debt tokens are burned against the vault's Alchemist position.
    /// @param amount Amount of debt tokens burned.
    event VaultDebtBurned(uint256 amount);

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