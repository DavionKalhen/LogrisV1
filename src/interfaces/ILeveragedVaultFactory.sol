// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ILeveragedVaultFactory {
    event Deposit(address indexed account, address indexed token, uint256 amount);
    event Withdraw(address indexed account, address indexed token, uint256 amount);
    event Mint(address indexed account, address indexed token, uint256 amount);
    event Burn(address indexed account, address indexed token, uint256 amount);
    
    function vaults(address) external view returns (address);
    function whitelisted_address(address) external view returns (bool);
}