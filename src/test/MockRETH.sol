pragma solidity 0.8.13;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract RETH is ERC20 {
    constructor() ERC20("RETH", "RETH") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}