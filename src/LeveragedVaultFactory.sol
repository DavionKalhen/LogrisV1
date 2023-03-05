// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "forge-std/console.sol";

contract LeveragedVaultFactory is ILeveragedVaultFactory, ReentrancyGuard, Ownable {   
    mapping (address => address) public vaults;

    constructor() {}

    function createVault(string memory _tokenName, string memory _tokenDescription, address _yieldToken, address _underlyingToken, address _leverager, address _alchemistV2, uint32 _underlyingSlippageBasisPoints, uint32 _debtSlippageBasisPoints) external onlyOwner returns (address) {
        require(vaults[_yieldToken] == address(0), "Vault already exists");
        //something also needs to create the leverager and pass that address in

        address vault = address(new LeveragedVault(_tokenName, _tokenDescription, _yieldToken, _underlyingToken, _leverager, _alchemistV2, _underlyingSlippageBasisPoints, _debtSlippageBasisPoints));
        vaults[_yieldToken] = vault;
        return vault;
    }
}