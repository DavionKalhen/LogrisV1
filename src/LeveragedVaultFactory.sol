// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./interfaces/ILeveragedVaultFactory.sol";
import "./LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "forge-std/console.sol";
contract LeveragedVaultFactory is ILeveragedVaultFactory, ReentrancyGuard, Ownable {   
    struct Account {
        mapping (address => uint256) balances;
    }

    mapping (address => address) public vaults;
    mapping (address => bool) public whitelisted_address;
    mapping (address => Account) accounts;
    constructor() {}

    function createVault(address _token) external onlyOwner returns (address) {
        require(vaults[_token] == address(0), "Vault already exists");
        address vault = address(new LeveragedVault(address(this), _token));
        IERC20(_token).approve(vault, type(uint256).max);
        vaults[_token] = vault;
        return vault;
    }

    function deposit(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        LeveragedVault(vaults[_token]).deposit(_amount, msg.sender);
        accounts[msg.sender].balances[vaults[_token]] += _amount;
    }

    function withdraw(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        require(accounts[msg.sender].balances[vaults[_token]] >= _amount, "Insufficient balance");
        LeveragedVault(vaults[_token]).withdraw(_amount, msg.sender, msg.sender);
        accounts[msg.sender].balances[vaults[_token]] -= _amount;
    }

    function mint(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        LeveragedVault(vaults[_token]).mint(_amount, msg.sender);
    }

    function whitelistAddress(address _address) external onlyOwner {
        whitelisted_address[_address] = true;
    }

    modifier whitelistOnly() {
        _;
    }
}