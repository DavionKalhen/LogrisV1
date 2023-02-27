pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStableMetaPool} from "../src/interfaces/curve/IStableMetaPool.sol";

contract CurveAlETHSwapTest is Test {
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    IERC20 alETHToken;
    IStableMetaPool curvePool;
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        curvePool = IStableMetaPool(alETHCurvePoolAddress);
        alETHToken = IERC20(alETHAddress);
    }

    //i,j determined by coins view method on contract
    function testETHtoAlETHSwap() public {
        uint256 amountToTrade = 100;
        uint256 minReceived = 50;

        uint256 output = curvePool.exchange(ethPoolIndex, alETHPoolIndex, amountToTrade, minReceived);
        require(output>minReceived);
        require(alETHToken.balanceOf(address(this))>0, "no coins in address");
    }
}
