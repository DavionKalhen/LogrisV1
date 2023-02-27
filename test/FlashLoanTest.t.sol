pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/euler/IFlashLoan.sol";
import "../src/interfaces/euler/DToken.sol";
import "../src/interfaces/euler/Markets.sol";

contract FlashLoanTest is Test, IFlashLoan  {
    address receiver;
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;

    uint flashloanAmount;
    bytes testData;
    Markets markets;
    DToken dToken;

    function setUp() public {
        flashloanAmount = 100;
        testData = abi.encode(wethAddress, flashloanAmount);
        markets = Markets(eulerMarketsAddress);
        address dTokenAddress = markets.underlyingToDToken(wethAddress);
        require(dTokenAddress != 0x0000000000000000000000000000000000000000, "dToken lookup fail");
        dToken = DToken(dTokenAddress);
    }

    function testFlashLoan() public {
        dToken.flashLoan(flashloanAmount, testData);
    }

    function onFlashLoan(bytes memory data) external {
        (address tokenAddress, uint amount) = abi.decode(data, (address, uint));
        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this))==amount, "wrong amount");
        token.transfer(msg.sender, amount); // repay
    }
}
