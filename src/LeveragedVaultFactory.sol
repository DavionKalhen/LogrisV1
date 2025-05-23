// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LeveragedVaultFactory is ILeveragedVaultFactory, ReentrancyGuard, Ownable {   
    mapping (address => address) public vaults;

    constructor() Ownable(msg.sender) {}

    function createVault(string memory tokenName,
                         string memory tokenDescription,
                         address yieldToken,
                         address underlyingToken,
                         address leverager,
                         address debtSource,
                         uint32 underlyingSlippageBasisPoints,
                         uint32 debtSlippageBasisPoints) external onlyOwner returns (address vault) {
        require(vaults[yieldToken] == address(0), "Vault already exists");
        //something also needs to create the leverager and pass that address in

        vault = address(new LeveragedVault(tokenName,
                                           tokenDescription,
                                           yieldToken,
                                           underlyingToken,
                                           leverager,
                                           debtSource,
                                           underlyingSlippageBasisPoints,
                                           debtSlippageBasisPoints));
        vaults[yieldToken] = vault;
    }
}