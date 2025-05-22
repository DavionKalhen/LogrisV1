// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// This test file is temporarily commented out due to compatibility issues with OpenZeppelin v5
// and requires updates to work with the latest dependencies.

/*
import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/balancer/IFlashLoanRecipient.sol";
import "../src/interfaces/balancer/IVault.sol";

contract FlashLoanTest is Test, IFlashLoanRecipient  {
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address balancerVaultAddress = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    IVault private vault = IVault(balancerVaultAddress);

    uint flashloanAmount;
    bytes testData;
    IERC20[] tokens;
    uint256[] amounts;
    uint256 balanceBefore;
    

    function setUp() public {
        flashloanAmount = 100;
        testData = abi.encode("testString");
        tokens = [IERC20(wethAddress)];
        amounts = [flashloanAmount*1e18];
        balanceBefore = tokens[0].balanceOf(address(this));
    }

    function testBalancerFlashLoan() public {
        vault.flashLoan(this, tokens, amounts, testData);
    }

    function receiveFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory userData) external override {
        assertEq(msg.sender, address(vault));
        (string memory testString) = abi.decode(userData, (string));
        assertEq(tokens.length,1);
        assertEq(tokens[0].balanceOf(address(this)) - balanceBefore, amounts[0]);
        assertEq(keccak256(abi.encodePacked((testString))),keccak256(abi.encodePacked(("testString"))), "wrong userData");
        assertEq(feeAmounts[0], 0);
        tokens[0].transfer(msg.sender, amounts[0]); // repay
    }
}
*/
