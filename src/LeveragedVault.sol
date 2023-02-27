// SPDX-License-Identifier: MIT
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "src/Leverager.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is ERC4626, Ownable {
    Leverager public leverager;
    mapping(address => uint256) public deposited;

    constructor(address _token, address _wrapper)
    ERC4626(IERC20(_token))
    //these strings should be provided by the factory if you want this contract to be reusable
    ERC20("Alchemix Leveraged Vault WETH", "lvyvETH") {
        leverager = new Leverager(_wrapper);
    }

    function deposit(uint256 assets, address receiver) public virtual override onlyOwner returns (uint256) {
        leverager.addAssets(assets);
        deposited[receiver] += assets;
        return super.deposit(assets, receiver);
    }

    function heldAssets() public view returns (uint256) {
        return leverager.heldAssets();
    }

    function leverage() public {
       leverager.leverage();
    }
}