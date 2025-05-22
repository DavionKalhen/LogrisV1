// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract RETH is ERC20 {
    constructor() ERC20("RETH", "RETH") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}