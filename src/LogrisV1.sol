// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./interfaces/ILogrisV1.sol";
import "./LogrisV1Vault.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract LogrisV1 is ILogrisV1, ReentrancyGuard, Ownable {   
    struct Account {
        mapping (address => uint256) balances;
    }

    mapping (address => address) public vaults;
    mapping (address => bool) public whitelisted_address;
    mapping (address => Account) accounts;
    constructor() {}

    function createVault(address _token) external onlyOwner returns (address) {
        require(vaults[_token] == address(0), "Vault already exists");
        address vault = address(new LogrisV1Vault(address(this), _token));
        vaults[_token] = vault;
        return vault;
    }

    function deposit(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        LogrisV1Vault(vaults[_token]).deposit(_amount, msg.sender);
        accounts[msg.sender].balances[vaults[_token]] += _amount;
    }

    function withdraw(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        require(accounts[msg.sender].balances[vaults[_token]] >= _amount, "Insufficient balance");
        LogrisV1Vault(vaults[_token]).withdraw(_amount, msg.sender, msg.sender);
        accounts[msg.sender].balances[vaults[_token]] -= _amount;
    }

    function mint(address _token, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_token] != address(0), "Vault does not exist");
        LogrisV1Vault(vaults[_token]).mint(_amount, msg.sender);
    }

    modifier whitelistOnly() {
        if(msg.sender != tx.origin)
            require(whitelisted_address[msg.sender], "Address not whitelisted");
        _;
    }
}