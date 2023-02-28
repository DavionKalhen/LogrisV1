pragma solidity 0.8.13;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ALETH is ERC20 {
    constructor() ERC20("alETH", "alETH") {}
    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}