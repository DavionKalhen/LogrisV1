// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    /// @notice Emitted when debt is repaid using yield tokens via AlchemistV3.repay().
    /// @param amount Amount of yield tokens provided for repayment.
    /// @param credit Amount of debt credit received.
    event VaultDebtRepaid(uint256 amount, uint256 credit);

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
     * @notice Repay debt using yield tokens (MYT) via AlchemistV3.repay()
     * @dev Cannot be called in the same block as vaultMintDebtTokens (CannotRepayOnMintBlock).
     * @param amount Amount of yield tokens to repay with
     * @return amountRepaid Actual yield tokens used for repayment
     */
    function vaultRepayWithYieldTokens(uint256 amount) external returns (uint256 amountRepaid);
    
    /**
     * @notice Get vault's position ID
     * @return positionId The vault's AlchemistV3 position ID
     */
    function getVaultPositionId() external view returns (uint256 positionId);

} 