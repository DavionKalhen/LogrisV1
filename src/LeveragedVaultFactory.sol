// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./interfaces/ITokenConverter.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";


/// @title LeveragedVaultFactory
/// @notice Factory that deploys EIP-1167 minimal proxy clones of LeveragedVault.
/// @dev Each clone is initialized with vault-specific parameters and registered in
///      the factory's registry keyed on (yieldToken, alchemist).
contract LeveragedVaultFactory is ILeveragedVaultFactory, Ownable {
    // ============ Constants ============

    uint256 constant BASIS_POINTS = 10_000;

    // ============ Custom Errors ============

    /// @dev Thrown when a required address parameter is address(0).
    error ZeroAddress();
    /// @dev Thrown when a provided address has no deployed bytecode.
    error NotAContract();
    /// @dev Thrown when a slippage parameter is >= 10000 basis points (100%).
    error SlippageTooHigh();
    /// @dev Thrown when a vault already exists for the given (yieldToken, alchemist) pair.
    error VaultAlreadyExists();
    /// @dev Thrown when the converter's tokens don't match the vault's yield/underlying tokens.
    error ConverterTokenMismatch();

    /// @notice The LeveragedVault implementation contract that clones delegate to
    address public immutable IMPLEMENTATION;

    /// @notice Maps vault key (keccak256(yieldToken, alchemist)) to vault address
    /// @dev Keyed on the pair to support multiple Alchemist deployments per yield token
    mapping (bytes32 => address) public vaultsByKey;

    /// @notice All vaults registered for a given yield token
    mapping (address => address[]) private _vaultsByYieldToken;

    /// @notice Creates the factory with a reference to the vault implementation.
    /// @param _implementation Address of the deployed LeveragedVault implementation contract.
    constructor(address _implementation) Ownable(msg.sender) {
        if (_implementation == address(0)) revert ZeroAddress();
        IMPLEMENTATION = _implementation;
    }

    /// @inheritdoc ILeveragedVaultFactory
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
    ) external onlyOwner returns (address vault) {
        if (yieldToken == address(0)) revert ZeroAddress();
        if (underlyingToken == address(0)) revert ZeroAddress();
        if (alchemist == address(0)) revert ZeroAddress();
        if (leverager == address(0)) revert ZeroAddress();
        if (weth == address(0)) revert ZeroAddress();
        if (converter == address(0)) revert ZeroAddress();
        if (flashLoanAdapter == address(0)) revert ZeroAddress();
        if (swapper == address(0)) revert ZeroAddress();
        if (underlyingSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        if (debtSlippageBasisPoints >= BASIS_POINTS) revert SlippageTooHigh();
        bytes32 vaultKey = keccak256(abi.encodePacked(yieldToken, alchemist));
        if (vaultsByKey[vaultKey] != address(0)) revert VaultAlreadyExists();

        if (yieldToken.code.length == 0) revert NotAContract();
        if (underlyingToken.code.length == 0) revert NotAContract();
        if (alchemist.code.length == 0) revert NotAContract();
        if (leverager.code.length == 0) revert NotAContract();
        if (weth.code.length == 0) revert NotAContract();
        if (converter.code.length == 0) revert NotAContract();
        if (flashLoanAdapter.code.length == 0) revert NotAContract();
        if (swapper.code.length == 0) revert NotAContract();

        // Semantic validation: converter tokens must match vault configuration
        if (ITokenConverter(converter).yieldToken() != yieldToken) revert ConverterTokenMismatch();
        if (ITokenConverter(converter).underlyingToken() != underlyingToken) revert ConverterTokenMismatch();

        vault = Clones.clone(IMPLEMENTATION);

        LeveragedVault(payable(vault)).initialize(
            yieldToken,
            underlyingToken,
            alchemist,
            leverager,
            underlyingSlippageBasisPoints,
            debtSlippageBasisPoints,
            converter,
            flashLoanAdapter,
            swapper,
            weth,
            msg.sender
        );

        vaultsByKey[vaultKey] = vault;
        _vaultsByYieldToken[yieldToken].push(vault);

        emit VaultCreated(vault, yieldToken, alchemist, leverager);
    }

    /// @inheritdoc ILeveragedVaultFactory
    function getVaultsByYieldToken(address yieldToken) external view returns (address[] memory) {
        return _vaultsByYieldToken[yieldToken];
    }
}
