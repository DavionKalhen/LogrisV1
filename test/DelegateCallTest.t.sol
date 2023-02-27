pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/CallerContract.sol";
import "../src/DelegateContract.sol";

contract DelegateCallTest is Test  {
    CallerContract caller;
    DelegateContract delegate;
    uint initialNum = 1;

    function setUp() public {
        delegate = new DelegateContract();
        caller = new CallerContract(address(delegate), initialNum);
    }

    function testSetNum() public {
        uint num1 = 2;
        uint num2 = 3;
        uint previousNum = caller.setNum(num1);
        require(initialNum==previousNum, "return value not what was expected");
        require(caller.getNum()==num1, "num not set correctly");
        require(initialNum==caller.getPreviousNum(), "delegate state not updated");
        previousNum = caller.setNum(num2);
        require(previousNum==num1, "previous num not set correctly");
        require(caller.getNum()==num2, "num not updated");
    }
}
