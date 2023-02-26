// SPDX-License-Identifier: MIT
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";



pragma solidity ^0.8.19;

contract LogrisV1Vault is ERC4626 {
    address logris;

    constructor(address _logris, address _token)
    ERC4626(IERC20(_token))
    ERC20("Logris V1 WETH Vault", "LOGV1WETH") {
        logris = _logris;
    }

    function deposit(uint256 assets, address receiver) public virtual override onlyLogris returns (uint256) {
        return super.deposit(assets, receiver);
    }

    

    modifier onlyLogris() {
        require(msg.sender == logris, "Only Logris can deposit");
        _;
    }
}