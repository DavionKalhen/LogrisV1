// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LeveragedVaultFactory is ILeveragedVaultFactory, Ownable {   
    /// @notice Maps vault key (keccak256(yieldToken, alchemist)) to vault address
    /// @dev Keyed on the pair to support multiple Alchemist deployments per yield token
    mapping (bytes32 => address) public vaultsByKey;

    /// @notice Convenience lookup: yield token → vault (returns first registered)
    mapping (address => address) public vaults;

    constructor() Ownable(msg.sender) {}

    function _requireContract(address target, string memory errorMessage) internal view {
        require(target.code.length > 0, errorMessage);
    }

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
    ) external onlyOwner returns (address vault) {
        require(yieldToken != address(0), "Yield token cannot be 0");
        require(underlyingToken != address(0), "Underlying token cannot be 0");
        require(alchemist != address(0), "Alchemist cannot be 0");
        require(leverager != address(0), "Leverager cannot be 0");
        require(weth != address(0), "WETH cannot be 0");
        require(defaultConverter != address(0), "Default converter cannot be 0");
        require(defaultFlashLoanAdapter != address(0), "Default flash loan adapter cannot be 0");
        require(defaultSwapper != address(0), "Default swapper cannot be 0");
        require(underlyingSlippageBasisPoints < 10000, "Underlying slippage basis points must be less than 10000");
        require(debtSlippageBasisPoints < 10000, "Debt slippage basis points must be less than 10000");
        bytes32 vaultKey = keccak256(abi.encodePacked(yieldToken, alchemist));
        require(vaultsByKey[vaultKey] == address(0), "Vault already exists for yield token + alchemist pair");

        _requireContract(yieldToken, "Yield token must be a contract");
        _requireContract(underlyingToken, "Underlying token must be a contract");
        _requireContract(alchemist, "Alchemist must be a contract");
        _requireContract(leverager, "Leverager must be a contract");
        _requireContract(weth, "WETH must be a contract");
        _requireContract(defaultConverter, "Default converter must be a contract");
        _requireContract(defaultFlashLoanAdapter, "Flash loan adapter must be a contract");
        _requireContract(defaultSwapper, "Swapper must be a contract");

        LeveragedVault newVault = new LeveragedVault(
            tokenName,
            tokenDescription,
            yieldToken,
            underlyingToken,
            alchemist,
            leverager,
            underlyingSlippageBasisPoints,
            debtSlippageBasisPoints,
            defaultConverter,
            defaultFlashLoanAdapter,
            defaultSwapper,
            weth
        );
        vault = address(newVault);
        vaultsByKey[vaultKey] = vault;
        if (vaults[yieldToken] == address(0)) {
            vaults[yieldToken] = vault;
        }

        // Transfer vault ownership to the caller (factory owner)
        newVault.transferOwnership(msg.sender);

        emit VaultCreated(vault, yieldToken, alchemist, leverager);
    }
}