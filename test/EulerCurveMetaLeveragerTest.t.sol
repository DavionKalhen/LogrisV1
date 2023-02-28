pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/ILeverager.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";

contract EulerCurveMetaLeveragerTest is Test {
    address wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address alchemixV2Address = 0xde399d26ed46B7b509561f1B9B5Ad6cc1EBC7261;
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    //i,j determined by coins view method on contract
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;
    ILeverager leverager;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, alchemixV2Address, alETHCurvePoolAddress, alETHPoolIndex, ethPoolIndex);
    }

    function testEulerCurveMetaLeveragerGetMethods() public {
        require(leverager.getYieldToken()==wstETHAddress);
    }
}