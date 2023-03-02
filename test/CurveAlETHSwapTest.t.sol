pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/wETH/IWETH.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStableMetaPool} from "../src/interfaces/curve/IStableMetaPool.sol";
import {ICurveFactory} from "../src/interfaces/curve/ICurveFactory.sol";

contract CurveAlETHSwapTest is Test {
    address curveFactoryAddress = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address curveETHAddress = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    IERC20 alETHToken;
    IWETH wETHToken;
    IStableMetaPool curvePool;
    ICurveFactory curveFactory;
    //i,j determined by coins view method on pool contract
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        curvePool = IStableMetaPool(alETHCurvePoolAddress);
        curveFactory = ICurveFactory(curveFactoryAddress);
        alETHToken = IERC20(alETHAddress);
        wETHToken = IWETH(wETHAddress);
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

    function testAlETHtowETHSwapByFactory() public {
        testETHtoAlETHSwap();
        uint256 alETHBalance = alETHToken.balanceOf(address(this));
        IERC20(alETHToken).approve(curveFactoryAddress, alETHBalance);
        require(alETHBalance>0, "no alETH to spend");

        (address poolAddress, uint256 amountOut) = curveFactory.get_best_rate(alETHAddress, curveETHAddress, alETHBalance);
        uint256 minReceived = alETHBalance/2;
        require(amountOut > minReceived);
        uint256 received = curveFactory.exchange{value:0 ether}(poolAddress, alETHAddress, curveETHAddress, alETHBalance, minReceived);
        require(received > minReceived);
        require(wETHToken.balanceOf(address(this)) > minReceived);
    }

    event ETHFallback();

    //callback when the output of the swap is eth.
    fallback() payable external {
        wETHToken.deposit{value: msg.value}();
        emit ETHFallback();
    }
}