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
    address eulerCallbackSender = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address curveFactoryAddress = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    //this is the alUSD alchemist
    //address alchemistV2Address = 0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd;
    ILeverager leverager;
    IAlchemistV2 alchemist;
    Whitelist whitelist;
    IWETH wETH;

    event DebugValue(uint);
    event DebugValue(int256);

    function setUp() public {
        vm.deal(address(this), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, eulerCallbackSender, alchemistV2Address, curveFactoryAddress);
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
        wETH.approve(address(leverager), type(uint256).max);
        wETH.approve(address(alchemistV2Address), type(uint256).max);
    }

    // denominated in underlying token
    function setVaultCapacity(address yieldToken, uint underlyingCapacity) public {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        console.log("old vault ceiling: ", params.maximumExpectedValue);
        emit DebugValue(params.maximumExpectedValue);
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(yieldToken, params.expectedValue + underlyingCapacity);
        params = alchemist.getYieldTokenParameters(yieldToken);
        console.log("new vault ceiling", params.maximumExpectedValue);
        emit DebugValue(params.maximumExpectedValue);

        uint newUnderlyingCapacity = params.maximumExpectedValue - params.expectedValue;
        console.log("vault capacity:", newUnderlyingCapacity);
        emit DebugValue(newUnderlyingCapacity);
        require(newUnderlyingCapacity+0.01 ether > underlyingCapacity, "failed to update vault capacity");
    }

    function deposit10Weth() internal {
        wETH.deposit{value:10 ether}();
        uint wETHBalance = wETH.balanceOf(address(this));
        require(10 ether==wETHBalance,"wETH failed to wrap");

        //minimumAmountOut is denominated in yield tokens so this is fragile.
        uint256 minimumAmountOut = 8 ether;
        alchemist.depositUnderlying(wstETHAddress, wETHBalance, address(this), minimumAmountOut);
    }

    function borrowAlETH(uint alETHAmount) internal returns(uint) {
        //wETH decimals = alAsset decimals
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
        require(result > 8 ether, "Deposit Balance lookup failed");
    }

    function testGetDebtBalance() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        uint alETHAmount = borrowAlETH(1 ether);
        int256 debtTokens = leverager.getDebtBalance(address(this));
        //for some reason the debt returned by Alchemist is not equal the alETH issued.
        //so I add .01 alETH to what we compare against
        require(debtTokens+0.01 ether > int256(alETHAmount), "Debt Balance lookup failed");
    }

    function testGetRedeemableBalance() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        borrowAlETH(1 ether);
        uint256 result = leverager.getRedeemableBalance(address(this));
        require(result+0.01 ether > 9 ether, "Redeemable Balance lookup failed");
    }

    function testGetBorrowCapacity() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        borrowAlETH(1 ether);
        uint borrowCapacity = leverager.getBorrowCapacity(address(this));
        emit DebugValue(borrowCapacity);
        require(borrowCapacity>3.95 ether, "Borrow Capacity too low");
        require(borrowCapacity<4.05 ether, "Borrow Capacity too high");
        alchemist.mint(borrowCapacity, address(this));
        IERC20 alETH = IERC20(alETHAddress);
        uint alETHBalance = alETH.balanceOf(address(this));
        require(alETHBalance > 4.95 ether);
    }

    function testGetFreeWithdrawCapacity() public {
        setVaultCapacity(wstETHAddress, 10.01 ether);
        deposit10Weth();
        uint withdrawCapacity = leverager.getFreeWithdrawCapacity(address(this));
        console.log("withdraw capacity before borrow: ", withdrawCapacity);
        emit DebugValue(withdrawCapacity);
        require(withdrawCapacity>=9.95 ether, "Withdraw capacity too low");
        require(withdrawCapacity<=10 ether, "Withdraw capacity too high");
        //then borrow eth and recalculate
        borrowAlETH(1 ether);
        withdrawCapacity = leverager.getFreeWithdrawCapacity(address(this));
        console.log("withdraw capacity after borrow: ", withdrawCapacity);
        emit DebugValue(withdrawCapacity);
        require(withdrawCapacity>=7.95 ether, "Withdraw capacity too low");
        require(withdrawCapacity<=8 ether, "Withdraw capacity too high");
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
        console.log("final deposit balance: ", depositBalance);
        emit DebugValue(depositBalance);
        int256 debtBalance = leverager.getDebtBalance(address(this));
        console.log("final debt balance: ", uint(debtBalance));
        emit DebugValue(debtBalance);
        require(depositBalance>=11 ether, "deposited funds too low");        
    }

    function testUnhinderedLeverage() public {
        wETH.deposit{value:10 ether}();
        uint wETHinitialDeposit = wETH.balanceOf(address(this));
        wETH.approve(address(leverager), wETHinitialDeposit);
        setVaultCapacity(wstETHAddress, 30 ether);

        alchemist.approveMint(address(leverager), wETHinitialDeposit*10000000);
        leverager.leverage(wETHinitialDeposit, 100, 400);
        
        uint depositBalance = leverager.getDepositedBalance(address(this));
        console.log("final deposit balance: ", depositBalance);
        emit DebugValue(depositBalance);
        require(depositBalance>=19 ether, "deposited funds too low");

        int256 debtBalance = leverager.getDebtBalance(address(this));
        console.log("final debt balance: ", uint(debtBalance));
        emit DebugValue(debtBalance);
        require(depositBalance>=11 ether, "deposited funds too low"); 
    }

    function testExistingBalancesLeverage() public {
        setVaultCapacity(wstETHAddress, 40 ether);
        deposit10Weth();
        borrowAlETH(1 ether);

        wETH.deposit{value:10 ether}();
        uint wETHinitialDeposit = wETH.balanceOf(address(this));
        wETH.approve(address(leverager), wETHinitialDeposit);

        alchemist.approveMint(address(leverager), wETHinitialDeposit*10000000);
        uint preLeverageDepositBalance = leverager.getDepositedBalance(address(this));
        int256 preLeverageDebtBalance = leverager.getDebtBalance(address(this));
        leverager.leverage(wETHinitialDeposit, 100, 300);
        
        uint postLeverageDepositBalance = leverager.getDepositedBalance(address(this));
        console.log("final deposit balance: ", postLeverageDepositBalance);
        emit DebugValue(postLeverageDepositBalance);

        uint depositDelta = postLeverageDepositBalance-preLeverageDepositBalance;
        console.log("deposit delta:", depositDelta);
        emit DebugValue(depositDelta);

        int256 postLeverageDebtBalance = leverager.getDebtBalance(address(this));
        console.log("final debt balance: ", uint(postLeverageDebtBalance));
        emit DebugValue(postLeverageDebtBalance);

        uint debtDelta = uint(postLeverageDebtBalance - preLeverageDebtBalance);
        console.log("debt delta: ", debtDelta);
        emit DebugValue(debtDelta);
    }

    function testWithdrawWithinCapacity() public {
        setVaultCapacity(wstETHAddress, 20 ether);
        deposit10Weth();
        borrowAlETH(1 ether);
        uint freeShares = leverager.getFreeWithdrawCapacity(address(this));
        console.log("freeShares: ", freeShares);
        alchemist.approveWithdraw(address(leverager), wstETHAddress, 10 ether);//last parameter denominated in shares
        leverager.withdrawUnderlying(freeShares, 100, 10);
        uint withdrawnFunds = wETH.balanceOf(address(this));
        require(withdrawnFunds>=7 ether,"Insufficient withdraw");
    }

    function testWithdrawRequiringBurn() public {
        setVaultCapacity(wstETHAddress, 20 ether);
        deposit10Weth();
        borrowAlETH(4 ether);
        uint totalShares = leverager.getTotalWithdrawCapacity(address(this));
        leverager.withdrawUnderlying(totalShares, 300, 10);
        uint withdrawnFunds = wETH.balanceOf(address(this));
        require(withdrawnFunds>=8 ether,"Insufficient withdraw");
    }
}