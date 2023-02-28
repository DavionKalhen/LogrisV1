// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ILeveragedVaultFactory {
    function vaults(address) external view returns (address);
}