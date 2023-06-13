// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "forge-std/console.sol";

contract LeveragedVaultFactory is ILeveragedVaultFactory, ReentrancyGuard, Ownable {   
    mapping (address => address) public vaults;

    constructor() {}

    function createVault(string memory tokenName,
                         string memory tokenDescription,
                         address yieldToken,
                         address underlyingToken,
                         address leverager,
                         address alchemistV2,
                         uint32 underlyingSlippageBasisPoints,
                         uint32 debtSlippageBasisPoints) external onlyOwner returns (address vault) {
        require(vaults[yieldToken] == address(0), "Vault already exists");
        //something also needs to create the leverager and pass that address in

        vault = address(new LeveragedVault(tokenName,
                                           tokenDescription,
                                           yieldToken,
                                           underlyingToken,
                                           leverager,
                                           alchemistV2,
                                           underlyingSlippageBasisPoints,
                                           debtSlippageBasisPoints));
        vaults[yieldToken] = vault;
    }
}