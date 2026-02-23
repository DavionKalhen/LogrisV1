// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title ILeveragedVaultFactory
/// @notice Interface for the factory that deploys EIP-1167 minimal proxy clones of LeveragedVault.
interface ILeveragedVaultFactory {
    /// @notice Emitted when a new vault is created.
    /// @param vault The newly deployed vault clone address.
    /// @param yieldToken The yield token the vault manages.
    /// @param alchemist The Alchemist contract the vault interacts with.
    /// @param leverager The leverager contract authorized for the vault.
    event VaultCreated(
        address indexed vault,
        address indexed yieldToken,
        address indexed alchemist,
        address leverager
    );

    /// @notice Returns the LeveragedVault implementation address that clones delegate to.
    /// @return The implementation contract address.
    function IMPLEMENTATION() external view returns (address);

    /// @notice Returns the vault address registered under a given key.
    /// @param key keccak256(abi.encodePacked(yieldToken, alchemist)).
    /// @return The vault address, or address(0) if none.
    function vaultsByKey(bytes32 key) external view returns (address);

    /// @notice Returns all vaults registered for a given yield token.
    /// @param yieldToken The yield token to query.
    /// @return Array of vault addresses.
    function getVaultsByYieldToken(address yieldToken) external view returns (address[] memory);

    /// @notice Deploys a new LeveragedVault clone and initializes it.
    /// @dev Only callable by the factory owner. Reverts if a vault already exists for
    ///      the (yieldToken, alchemist) pair.
    /// @param yieldToken Yield-bearing token deposited into Alchemist.
    /// @param underlyingToken Underlying token accepted for user deposits.
    /// @param alchemist AlchemistV3 contract address.
    /// @param leverager Leverager contract authorized for leverage operations.
    /// @param underlyingSlippageBasisPoints Default slippage for underlying operations.
    /// @param debtSlippageBasisPoints Default slippage for debt token swaps.
    /// @param converter Token converter for underlying <-> yield conversions.
    /// @param flashLoanAdapter Flash loan adapter for leverage/deleverage.
    /// @param swapper Swap adapter for debt token trades.
    /// @param weth WETH contract address.
    /// @return vault The newly deployed vault clone address.
    function createVault(
        address yieldToken,
        address underlyingToken,
        address alchemist,
        address leverager,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints,
        address converter,
        address flashLoanAdapter,
        address swapper,
        address weth
    ) external returns (address vault);
}
