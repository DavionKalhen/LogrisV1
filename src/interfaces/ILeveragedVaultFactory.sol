// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface ILeveragedVaultFactory {
    /// @notice Emitted when a new vault is created
    event VaultCreated(
        address indexed vault,
        address indexed yieldToken,
        address indexed alchemist,
        address leverager
    );

    function vaults(address) external view returns (address);

    function createVault(
        string memory tokenName,
        string memory tokenDescription,
        address yieldToken,
        address underlyingToken,
        address alchemist,
        address leverager,
        uint32 underlyingSlippageBasisPoints,
        uint32 debtSlippageBasisPoints,
        address defaultConverter,
        address defaultFlashLoanAdapter,
        address defaultSwapper,
        address weth
    ) external returns (address vault);
}