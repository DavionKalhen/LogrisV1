pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/euler/IFlashLoan.sol";

contract FlashLoanTest is Test {
    address receiver;
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    IFlashLoan flashlender = IFlashLoan(0x07df2ad9878F8797B4055230bbAE5C808b8259b3);
    bytes myCallData;

    function setUp() public {
        receiver = vm.addr(1);
        myCallData = "0x1234";
        vm.deal(receiver, 1 ether);
    }

    function testFlashLoanCallback() public {
        uint256 flashloanAmount = 100;
        require(flashlender.flashLoan(receiver, wethAddress, flashloanAmount, myCallData), "flash loan failed");        
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes32) {
        require(fee == 0, "no fee allowed");
        require(IERC20(token).balanceOf(initiator)==amount,"tokens did not arrive");
        require(keccak256(data)==keccak256(myCallData),"calldata misformed");
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
