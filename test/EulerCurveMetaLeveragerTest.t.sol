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

        //add pool capacity
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(wstETHAddress, type(uint256).max);

        //setup underlying approval
        wETH = IWETH(wETHAddress);
        wETHDecimalOffset=10**wETH.decimals();
        wETH.approve(address(leverager), type(uint256).max);
        wETH.approve(address(alchemistV2Address), type(uint256).max);
    }

    function deposit10Weth() internal {
        wETH.deposit{value:10 ether}();
        uint wETHBalance = wETH.balanceOf(address(this));
        require(10*wETHDecimalOffset==wETHBalance,"wETH failed to wrap");

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
        deposit10Weth();
        uint256 result = leverager.getDepositedBalance(address(this));
        require(result > 8*wETHDecimalOffset, "Deposit Balance lookup failed");
    }

    function testGetDebtBalance() public {
        deposit10Weth();
        uint alETHAmount = borrow1alETH();
        int256 debtTokens = leverager.getDebtBalance(address(this));
        //for some reason the debt returned by Alchemist is not equal the alETH issued.
        //so I add .01 alETH to what we compare against
        require(debtTokens+10**17 > int256(alETHAmount), "Debt Balance lookup failed");
    }

    function testGetRedeemableBalance() public {
        deposit10Weth();
        uint alETHAmount = borrow1alETH();
        uint256 result = leverager.getRedeemableBalance(address(this));
        require(result+10**17 > 9*wETHDecimalOffset, "Redeemable Balance lookup failed");
    }

    function setVaultCapacity(uint capacity) public {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(wstETHAddress);
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(wstETHAddress, params.expectedValue+capacity);
    }

    function testVaultCapacityFullLeverage() public {
        setVaultCapacity(0);
        vm.expectRevert("Vault is full");
        leverager.leverage(10, 9);
    }

    function testDepositPoolGreaterThanVaultCapacityLeverage() public {
        wETH.deposit{value:10 ether}();
        setVaultCapacity(8*wETHDecimalOffset);
        leverager.leverage(10*wETHDecimalOffset, 9*wETHDecimalOffset);
    }

    function testVaultCapacityBetweenDepositPoolAndMaxLeverage() public {
        
    }

    function testUnhinderedLeverage() public {
        wETH.deposit{value:10 ether}();
        uint wETHinitialDeposit = wETH.balanceOf(address(this));
        wETH.approve(address(leverager), wETHinitialDeposit);
        alchemist.approveMint(address(leverager), wETHinitialDeposit*10000000);
        leverager.leverage(wETHinitialDeposit, wETHinitialDeposit-(wETHinitialDeposit/5));
        uint depositBalance = leverager.getDepositedBalance(address(this));

        require(depositBalance>wETHinitialDeposit, "Leverage below expected value");
        int256 debtBalance = leverager.getDebtBalance(address(this));
        vm.stopPrank();
    }
    //probably also want to test situations where there is existing balance and debt on the caller
}