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
    mapping (address => address) wrapperToUnderlying;

    constructor() {}

    function createVault(address _token, address _wrapper) external onlyOwner returns (address) {
        require(vaults[_wrapper] == address(0), "Vault already exists");
        address vault = address(new LeveragedVault(_token, _wrapper));
        IERC20(_token).approve(vault, type(uint256).max);
        vaults[_wrapper] = vault;
        wrapperToUnderlying[_wrapper] = _token;
        return vault;
    }

    function deposit(address _wrapper, uint256 _amount) external nonReentrant whitelistOnly {
        require(vaults[_wrapper] != address(0), "Vault does not exist");
        address _token = wrapperToUnderlying[_wrapper];
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        console.log(_token);
        console.log("Balance :", IERC20(_token).balanceOf(address(this)));
        IERC20(_token).approve(vaults[_wrapper], _amount);
        LeveragedVault(vaults[_wrapper]).deposit(_amount, msg.sender);
        accounts[msg.sender].balances[vaults[_wrapper]] += _amount;
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