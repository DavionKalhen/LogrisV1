pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStableMetaPool} from "../src/interfaces/curve/IStableMetaPool.sol";

contract CurveAlETHSwapTest is Test {
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    IERC20 alETHToken;
    IStableMetaPool curvePool;
    //i,j determined by coins view method on contract
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        curvePool = IStableMetaPool(alETHCurvePoolAddress);
        alETHToken = IERC20(alETHAddress);
    }

    function testETHtoAlETHSwap() public {
        uint256 amountToTrade = 10000000000000000000;
        uint256 minReceived =    5000000000000000000;

        uint256 output = curvePool.exchange{value:10 ether}(ethPoolIndex, alETHPoolIndex, amountToTrade, minReceived);
        require(output>minReceived);
        require(alETHToken.balanceOf(address(this))>0, "no coins in address");
    }

    function testAlETHtoETHSwap() public {
        testETHtoAlETHSwap();
        alETHToken.approve(alETHCurvePoolAddress, type(uint256).max);
        uint256 alETHBalance = alETHToken.balanceOf(address(this));
        require(alETHBalance>0, "no alETH to spend");
        uint256 amountToTrade = alETHBalance;
        uint256 minReceived = amountToTrade/2;
        uint256 output = curvePool.exchange{value:0 ether}(alETHPoolIndex, ethPoolIndex, amountToTrade, minReceived);
        require(output>minReceived);
        require(alETHToken.balanceOf(address(this))==0, "failed to spend all coins");
    }

    //callback when the output of the swap is eth.
    fallback() payable external {
        console.log("Received");
    }
}