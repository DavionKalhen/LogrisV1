pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../src/interfaces/wETH/IWETH.sol";
import "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/alchemist/Whitelist.sol";

contract AlchemistV2Test is Test {
    address uniswapv2RouterAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address yvETHAddress = 0xa258C4606Ca8206D8aA700cE2143D7db854D168c;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    //this is the alUSD alchemist
    //address alchemistV2Address = 0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd;
    IAlchemistV2 alchemist;
    Whitelist whitelist;
    IWETH wETH;
    uint wETHDecimalOffset;
    uint256 constant minimumCollateralization = 2000000000000000000;

    event DebugValue(uint);

    function setUp() public {
        vm.deal(address(this), 200 ether);
        //setup whitelist
        alchemist = IAlchemistV2(alchemistV2Address);
        whitelist = Whitelist(alchemist.whitelist());
        vm.startPrank(whitelist.owner());
        whitelist.add(address(this));
        vm.stopPrank();
        require(whitelist.isWhitelisted(address(this)), "failed to whitelist");

        //setup underlying approval
        wETH = IWETH(wETHAddress);
        wETHDecimalOffset=10**wETH.decimals();
        wETH.approve(address(alchemistV2Address), type(uint256).max);
    }

    // denominated in underlying token
    function setVaultCapacity(address yieldToken, uint underlyingCapacity) public {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        console.log("old ceiling");
        emit DebugValue(params.maximumExpectedValue);
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(yieldToken, params.expectedValue + underlyingCapacity);
        params = alchemist.getYieldTokenParameters(yieldToken);
        uint newUnderlyingCapacity = params.maximumExpectedValue - params.expectedValue;
        console.log("new ceiling");
        emit DebugValue(params.maximumExpectedValue);
        console.log("capacity");
        emit DebugValue(params.maximumExpectedValue-params.expectedValue);
        emit DebugValue(newUnderlyingCapacity);
        require(newUnderlyingCapacity+0.01 ether > underlyingCapacity, "failed to update vault capacity");
    }

    function testDepositUnderlying() public {
        wETH.deposit{value:10 ether}();
        wETH.approve(alchemistV2Address, wETH.balanceOf(address(this)));
        setVaultCapacity(wstETHAddress, 10.01 ether);
        uint depositedShares = alchemist.depositUnderlying(wstETHAddress, 10 ether, address(this), 1 ether);
    }
}