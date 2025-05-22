// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface ILeveragedVaultFactory {
    function vaults(address) external view returns (address);
}