pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/iDai.sol";
import "../src/LogrisV1.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import "../src/interfaces/ILogrisV1Vault.sol";

contract TestContract is Test {

    IAlchemistV2 alchemist;
    LogrisV1 logris;
    iDAI dai;

    address daiOwner = 0xdDb108893104dE4E1C6d0E47c42237dB4E617ACc;
    IUniswapV2Router02 uniswap;

    function setUp() public {
        address user1 = vm.addr(1);
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        
        alchemist = IAlchemistV2(0xde399d26ed46B7b509561f1B9B5Ad6cc1EBC7261);
        address alchemixOwner = alchemist.admin();
        logris = new LogrisV1();
        dai = iDAI(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        vm.deal(user1, 200 ether);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(dai);
        uniswap = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        vm.prank(user1);
        uniswap.swapExactETHForTokens{value:10 ether}(1, path, user1, block.timestamp + 10000);
        vm.prank(alchemixOwner);
        address whitelist = alchemist.whitelist();
        console.log(whitelist);
    }

    function testDAIBalance() public {
        assertGt(dai.balanceOf(vm.addr(1)), 100 ether);}

    function testCanCreateVault() public {
        logris.createVault(address(dai));
    }

    function testDepositToVault() public {
        logris.createVault(address(dai));
        dai.approve(address(logris), 100 ether);
        logris.deposit(address(dai), 100 ether);
        ILogrisV1Vault vault = ILogrisV1Vault(logris.vaults(address(dai)));
        assertEq(vault.totalAssets(), 100 ether);
    }
}
