pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/iDai.sol";
import "../src/LeveragedVaultFactory.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import "../src/interfaces/ILeveragedVault.sol";
import "../src/interfaces/alchemist/Whitelist.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";

contract LeveragedVaultTest is Test {
    address daiVaultAddress = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address iDAIAddress = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address uniswapv2RouterAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address curveFactoryAddress = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
 
    IAlchemistV2 alchemist;
    LeveragedVault leveragedVault;
    iDAI dai;
    address user1;
    address daiOwner = 0xdDb108893104dE4E1C6d0E47c42237dB4E617ACc;
    IUniswapV2Router02 uniswap;
    Whitelist whitelist;
    EulerCurveMetaLeverager leverager;
    IWETH wETH;

    function setUp() public {
        user1 = vm.addr(1);
        vm.deal(user1, 200 ether);
        vm.deal(vm.addr(2), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, alchemistV2Address, curveFactoryAddress);

        alchemist = IAlchemistV2(alchemistV2Address);
        address alchemixOwner = alchemist.admin();
        
        whitelist = Whitelist(alchemist.whitelist());
        vm.startPrank(whitelist.owner());
        whitelist.add(address(leverager));
        whitelist.add(address(this));

        vm.stopPrank();
        vm.startPrank(user1);
        //setup underlying approval
        wETH = IWETH(wETHAddress);
        wETH.approve(address(leverager), type(uint256).max);
        wETH.approve(address(alchemistV2Address), type(uint256).max);
        vm.stopPrank();
    }
    function setVaultCapacity(address yieldToken, uint underlyingCapacity) public {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        console.log("old vault ceiling: ", params.maximumExpectedValue);
        vm.prank(alchemist.admin());
        alchemist.setMaximumExpectedValue(yieldToken, params.expectedValue + underlyingCapacity);
        params = alchemist.getYieldTokenParameters(yieldToken);
        console.log("new vault ceiling", params.maximumExpectedValue);

        uint newUnderlyingCapacity = params.maximumExpectedValue - params.expectedValue;
        console.log("vault capacity:", newUnderlyingCapacity);
        require(newUnderlyingCapacity+0.01 ether > underlyingCapacity, "failed to update vault capacity");
    }
    function initLeveragedVault() public {
            leveragedVault = new LeveragedVault{value: 0.1 ether}(
            "WETH Leverage Vault",
            "WETHLEV",
            wstETHAddress,
            wETHAddress,
            address(leverager),
            alchemistV2Address,
            100,
            300
        );
        setVaultCapacity(wstETHAddress, 1000 ether);
        vm.prank(whitelist.owner());
        whitelist.add(address(leveragedVault));


    }
    function testETHDepositToVault() public {
        initLeveragedVault();
        vm.startPrank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        uint256 heldAssets = leveragedVault.getVaultRedeemableBalance();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint supply = leveragedVault.totalSupply();
        console.log("Supply: ", supply);
        console.log("User Balance: ", userBalance);
        uint256 value = leveragedVault.convertSharesToUnderlyingTokens(userBalance);
        assertEq(value, 10 ether);
        assertEq(heldAssets, 10 ether);
    }
    function testMultipleETHDepositToVault() public {
        initLeveragedVault();
        vm.startPrank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.depositUnderlying{value: 10 ether}();
        uint256 heldAssets = leveragedVault.getVaultRedeemableBalance();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint supply = leveragedVault.totalSupply();
        console.log("Supply: ", supply);
        console.log("User Balance: ", userBalance);
        uint256 value = leveragedVault.convertSharesToUnderlyingTokens(userBalance);
        assertEq(value, 20 ether);
        assertEq(heldAssets, 20 ether);
    }

    function testMultipleUsersETHDepositToVault() public {
        initLeveragedVault();
        vm.startPrank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        vm.stopPrank();
        vm.startPrank(vm.addr(2));
        leveragedVault.depositUnderlying{value: 10 ether}();
        vm.stopPrank();
        vm.startPrank(user1);
        uint256 heldAssets = leveragedVault.getVaultRedeemableBalance();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint256 user2Balance = leveragedVault.balanceOf(vm.addr(2));
        uint supply = leveragedVault.totalSupply();
        console.log("Supply: ", supply);
        console.log("User Balance: ", userBalance);
        uint256 value = leveragedVault.convertSharesToUnderlyingTokens(userBalance);
        uint256 value2 = leveragedVault.convertSharesToUnderlyingTokens(user2Balance);
        assertEq(value, 10 ether);
        assertEq(value2, 10 ether);
        assertEq(heldAssets, 20 ether);
    }

    function testETHDepositToVaultWithLeverager() public {
        initLeveragedVault();
        vm.startPrank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        uint256 heldAssets = leveragedVault.getVaultRedeemableBalance();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint supply = leveragedVault.totalSupply();
        console.log("Supply: ", supply);
        console.log("User Balance: ", userBalance);
        uint256 value = leveragedVault.getVaultDepositedBalance();
        assertGt(value, 10 ether);
    }

    function testETHDepositToValutWithThreeUsersAndLeverager() public {
        initLeveragedVault();
        vm.prank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        vm.prank(vm.addr(2));
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        vm.deal(vm.addr(3), 200 ether);
        vm.prank(vm.addr(3));
        leveragedVault.depositUnderlying{value: 10 ether}();
        uint256 redeemable = leveragedVault.getVaultRedeemableBalance();
        uint256 withdrawCap = leverager.getWithdrawCapacity(address(leveragedVault));
        uint256 totalAssets = leveragedVault.totalAssets();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint256 user2Balance = leveragedVault.balanceOf(vm.addr(2));
        uint256 user3Balance = leveragedVault.balanceOf(vm.addr(3));
        uint supply = leveragedVault.totalSupply();
        console.log("Redeemable  : ", redeemable);
        console.log("Total Assets: ", totalAssets);
        console.log("Withdraw Cap: ", withdrawCap);
        console.log("User 1 Balance: ", userBalance);
        console.log("User 2 Balance: ", user2Balance);
        console.log("User 3 Balance: ", user3Balance);
        uint256 value = leveragedVault.convertSharesToUnderlyingTokens(userBalance);
        uint256 value2 = leveragedVault.convertSharesToUnderlyingTokens(user2Balance);
        uint256 value3 = leveragedVault.convertSharesToUnderlyingTokens(user3Balance);
        console.log("User 1 Value: ", value);
        console.log("User 2 Value: ", value2);
        console.log("User 3 Value: ", value3);

        uint256 worth = leveragedVault.getVaultDepositedBalance() + leveragedVault.getDepositPoolBalance();
        assertGt(worth, 20 ether);
        assertLt(userBalance, user2Balance);
        
    }

    function testETHDepositToValutWithFourUsersAndLeverager() public {
        initLeveragedVault();
        vm.prank(user1);
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        vm.prank(vm.addr(2));
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        vm.deal(vm.addr(3), 200 ether);
        vm.prank(vm.addr(3));
        leveragedVault.depositUnderlying{value: 10 ether}();
        vm.deal(vm.addr(4), 200 ether);
        vm.prank(vm.addr(4));
        leveragedVault.depositUnderlying{value: 10 ether}();
        leveragedVault.leverage();
        uint256 redeemable = leveragedVault.getVaultRedeemableBalance();
        uint256 withdrawCap = leverager.getWithdrawCapacity(address(leveragedVault));
        uint256 totalAssets = leveragedVault.totalAssets();
        uint256 userBalance = leveragedVault.balanceOf(user1);
        uint256 user2Balance = leveragedVault.balanceOf(vm.addr(2));
        uint256 user3Balance = leveragedVault.balanceOf(vm.addr(3));
        uint256 user4Balance = leveragedVault.balanceOf(vm.addr(4));
        uint supply = leveragedVault.totalSupply();
        console.log("Redeemable  : ", redeemable);
        console.log("Total Assets: ", totalAssets);
        console.log("Withdraw Cap: ", withdrawCap);
        console.log("User 1 Balance: ", userBalance);
        console.log("User 2 Balance: ", user2Balance);
        console.log("User 3 Balance: ", user3Balance);
        console.log("User 4 Balance: ", user4Balance);
        uint256 value = leveragedVault.convertSharesToUnderlyingTokens(userBalance);
        uint256 value2 = leveragedVault.convertSharesToUnderlyingTokens(user2Balance);
        uint256 value3 = leveragedVault.convertSharesToUnderlyingTokens(user3Balance);
        uint256 value4 = leveragedVault.convertSharesToUnderlyingTokens(user4Balance);
        console.log("User 1 Value: ", value);
        console.log("User 2 Value: ", value2);
        console.log("User 3 Value: ", value3);
        console.log("User 4 Value: ", value4);
        
        uint256 worth = leveragedVault.getVaultDepositedBalance() + leveragedVault.getDepositPoolBalance();
        assertGt(worth, 20 ether);
        assertLt(userBalance, user2Balance);
        
    }    
    // function testLeverageCall() public {
    //     leveragedVaultFactory.createVault(address(dai), daiVaultAddress);
    //     leveragedVaultFactory.whitelistAddress(address(this));
    //     vm.startPrank(user1);
    //     dai.approve(address(leveragedVaultFactory), 10 ether);
    //     leveragedVaultFactory.deposit(daiVaultAddress, 10 ether);
    //     vm.stopPrank();
    //     ILeveragedVault vault = ILeveragedVault(leveragedVaultFactory.vaults(daiVaultAddress));
    //     uint256 heldAssets = vault.getVaultRedeemableBalance();
    //     vm.prank(user1);
    //     vault.leverage();
    //     console.log("heldAssets: %s", heldAssets);
    // }
}
