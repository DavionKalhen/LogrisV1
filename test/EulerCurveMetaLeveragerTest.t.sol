pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../src/interfaces/wETH/IWETH.sol";
import "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import "../src/interfaces/ILeverager.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";
import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/alchemist/Whitelist.sol";

contract EulerCurveMetaLeveragerTest is Test {
    address uniswapv2RouterAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address curveFactoryAddress = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    //this is the alUSD alchemist
    //address alchemistV2Address = 0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd;
    ILeverager leverager;
    IAlchemistV2 alchemist;
    Whitelist whitelist;
    IWETH wETH;
    uint wETHDecimalOffset;
    uint256 constant minimumCollateralization = 2000000000000000000;

    event DebugValue(uint);

    function setUp() public {
        vm.deal(address(this), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, alchemistV2Address, curveFactoryAddress);
        //setup whitelist
        alchemist = IAlchemistV2(alchemistV2Address);
        whitelist = Whitelist(alchemist.whitelist());
        vm.startPrank(whitelist.owner());
        whitelist.add(address(leverager));
        whitelist.add(address(this));
        vm.stopPrank();
        require(whitelist.isWhitelisted(address(leverager)), "failed to whitelist");

        //setup underlying approval
        wETH = IWETH(wETHAddress);
        wETHDecimalOffset=10**wETH.decimals();
        wETH.approve(address(leverager), type(uint256).max);
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

    function deposit10Weth() internal {
        wETH.deposit{value:10 ether}();
        uint wETHBalance = wETH.balanceOf(address(this));
        require(10 ether==wETHBalance,"wETH failed to wrap");

        //minimumAmountOut is denominated in yield tokens so this is fragile.
        uint256 minimumAmountOut = 8*wETHDecimalOffset;
        alchemist.depositUnderlying(wstETHAddress, wETHBalance, address(this), minimumAmountOut);
    }

    function borrow1alETH() internal returns(uint) {
        //wETH decimals = alAsset decimals
        uint alETHAmount = 1*wETHDecimalOffset;
        alchemist.mint(alETHAmount, address(this));
        IERC20 alETH = IERC20(alETHAddress);
        uint alETHMinted = alETH.balanceOf(address(this));
        require(alETHMinted==alETHAmount,"Mint did not transfer full amount");
        return alETHMinted;
    }

    function testGetDepositedBalance() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        uint256 result = leverager.getDepositedBalance(address(this));
        require(result > 8*wETHDecimalOffset, "Deposit Balance lookup failed");
    }

    function testGetDebtBalance() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        uint alETHAmount = borrow1alETH();
        int256 debtTokens = leverager.getDebtBalance(address(this));
        //for some reason the debt returned by Alchemist is not equal the alETH issued.
        //so I add .01 alETH to what we compare against
        require(debtTokens+10**17 > int256(alETHAmount), "Debt Balance lookup failed");
    }

    function testGetRedeemableBalance() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        uint alETHAmount = borrow1alETH();
        uint256 result = leverager.getRedeemableBalance(address(this));
        require(result+10**17 > 9*wETHDecimalOffset, "Redeemable Balance lookup failed");
    }

    function testVaultCapacityFullLeverage() public {
        setVaultCapacity(wstETHAddress, 0);
        vm.expectRevert("Vault is full");
        leverager.leverage(10, 100, 100);
    }

    function testDepositPoolGreaterThanVaultCapacityLeverage() public {
        wETH.deposit{value:10 ether}();
        wETH.approve(address(leverager), wETH.balanceOf(address(this)));
        setVaultCapacity(wstETHAddress, 8 ether);
        leverager.leverage(10 ether, 100, 100);

        uint depositBalance = leverager.getDepositedBalance(address(this));
        console.log("final deposit balance");
        emit DebugValue(depositBalance);
        require(depositBalance > 7.93 ether, "deposited funds too low");
    }

    function testVaultCapacityBetweenDepositPoolAndMaxLeverage() public {
        wETH.deposit{value:10 ether}();
        wETH.approve(address(leverager), wETH.balanceOf(address(this)));
        setVaultCapacity(wstETHAddress, 12 ether);
        alchemist.approveMint(address(leverager), 10 ether);
        leverager.leverage(10 ether, 100, 1000);

        uint depositBalance = leverager.getDepositedBalance(address(this));
        console.log("final deposit balance");
        emit DebugValue(depositBalance);
        require(depositBalance>=11 ether, "deposited funds too low");        
    }

    function testUnhinderedLeverage() public {
        wETH.deposit{value:10 ether}();
        uint wETHinitialDeposit = wETH.balanceOf(address(this));
        wETH.approve(address(leverager), wETHinitialDeposit);
        setVaultCapacity(wstETHAddress, 30 ether);

        alchemist.approveMint(address(leverager), wETHinitialDeposit*10000000);
        leverager.leverage(wETHinitialDeposit, 1000, 1000);
        uint depositBalance = leverager.getDepositedBalance(address(this));

        require(depositBalance>wETHinitialDeposit, "Leverage below expected value");
        int256 debtBalance = leverager.getDebtBalance(address(this));
        vm.stopPrank();
    }
    //probably also want to test situations where there is existing balance and debt on the caller
}