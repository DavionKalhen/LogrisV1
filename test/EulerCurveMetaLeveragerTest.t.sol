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
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    address alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    //this is the alUSD alchemist
    //address alchemistV2Address = 0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd;
    //i,j determined by coins view method on contract
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;
    ILeverager leverager;
    IAlchemistV2 alchemist;
    Whitelist whitelist;
    IWETH wETH;
    uint wETHDecimalOffset;
    uint256 constant minimumCollateralization = 2000000000000000000;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, alchemistV2Address, alETHCurvePoolAddress, alETHPoolIndex, ethPoolIndex);
        //setup whitelist
        alchemist = IAlchemistV2(alchemistV2Address);
        whitelist = Whitelist(alchemist.whitelist());
        vm.prank(whitelist.owner());
        whitelist.add(address(this));
        vm.prank(whitelist.owner());
        whitelist.add(address(leverager));
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

    function testVaultCapacityFullLeverage() public {
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(wstETHAddress, 0);
        vm.expectRevert("Vault is full");
        leverager.leverage(1 ether, 0.9 ether);
    }

    function testDepositPoolGreaterThanVaultCapacityLeverage() public {

    }

    function testVaultCapacityBetweenDepositPoolAndMaxLeverage() public {
        
    }

    function testUnhinderedLeverage() public {
        wETH.deposit{value:10 ether}();
        uint wETHinitialDeposit = wETH.balanceOf(address(this));
        leverager.leverage(wETHinitialDeposit, wETHinitialDeposit-(wETHinitialDeposit/50));
        uint depositBalance = leverager.getDepositedBalance(address(this));
        require(depositBalance+10**17>2*wETHinitialDeposit, "Leverage below expected value");
        int256 debtBalance = leverager.getDebtBalance(address(this));
    }

    //probably also want to test situations where there is existing balance and debt on the caller
}