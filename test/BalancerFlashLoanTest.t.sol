pragma solidity 0.8.19;

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
    

    function setUp() public {
        flashloanAmount = 100;
        testData = abi.encode("testString");
        tokens = [IERC20(wethAddress)];
        amounts = [flashloanAmount*1e18];
    }

    function testBalancerFlashLoan() public {
        vault.flashLoan(this, tokens, amounts, testData);
    }

    function receiveFlashLoan(IERC20[] memory tokens, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory userData) external override {
        require(msg.sender == address(vault));
        (string memory testString) = abi.decode(userData, (string));
        require(tokens.length==1, "wrong token count");
        require(tokens[0].balanceOf(address(this))==amounts[0], "wrong amount");
        require(keccak256(abi.encodePacked((testString))) == keccak256(abi.encodePacked(("testString"))), "wrong userData");
        require(feeAmounts[0]==0, "wrong feeAmounts");
        tokens[0].transfer(msg.sender, amounts[0]); // repay
    }
}
