// SPDX-License-Identifier: MIT
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is ERC4626 {
    address owner;

    constructor(address _owner, address _token)
    ERC4626(IERC20(_token))
    //these strings should be provided by the factory if you want this contract to be reusable
    ERC20("Alchemix Leveraged Vault WETH", "lvyvETH") {
        owner = _owner;
    }

    function deposit(uint256 assets, address receiver) public virtual override onlyOwner returns (uint256) {
        return super.deposit(assets, receiver);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }
}