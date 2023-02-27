pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../src/interfaces/alchemist/IAlchemistV2.sol";
import "../src/interfaces/iDai.sol";
import "../src/LeveragedVaultFactory.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/uniswap/IUniswapV2Router02.sol";
import "../src/interfaces/ILeveragedVault.sol";
import "../src/interfaces/alchemist/Whitelist.sol";

contract LeveragedVaultTest is Test {

    IAlchemistV2 alchemist;
    LeveragedVault owner;
    iDAI dai;
    address user1;
    address daiOwner = 0xdDb108893104dE4E1C6d0E47c42237dB4E617ACc;
    IUniswapV2Router02 uniswap;
    Whitelist whitelist;
    LeveragedVaultFactory logris;
    address daiVaultAddress = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;

    function setUp() public {
        user1 = vm.addr(1);
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        
        alchemist = IAlchemistV2(0xde399d26ed46B7b509561f1B9B5Ad6cc1EBC7261);
        address alchemixOwner = alchemist.admin();
        dai = iDAI(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        logris = new LeveragedVaultFactory();
        
        vm.deal(user1, 200 ether);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(dai);
        uniswap = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

        vm.prank(user1);
        uniswap.swapExactETHForTokens{value:10 ether}(1, path, user1, block.timestamp + 10000);
        
        vm.prank(alchemixOwner);
        whitelist = new Whitelist();
        vm.prank(alchemixOwner);
        whitelist.add(address(logris));
        bytes32 b7 = bytes32(abi.encode(address(whitelist))); //works
        vm.store(address(alchemist), bytes32(uint256(11)), b7);
    }

    function testDAIBalance() public {
        assertGt(dai.balanceOf(user1), 100 ether);
    }

    function testCanCreateVault() public {
        address ret_vault = logris.createVault(address(dai), daiVaultAddress);
        address vault = logris.vaults(daiVaultAddress);
        assertEq(ret_vault, vault);
    }

    function testWhitelisted() public {
        bool whitelisted = whitelist.isWhitelisted(address(logris));
        assertEq(whitelisted, true);
    }

    function testDepositToVault() public {
        logris.createVault(address(dai), daiVaultAddress);
        logris.whitelistAddress(address(this));
        vm.startPrank(user1);
        dai.approve(address(logris), 100 ether);
        logris.deposit(daiVaultAddress, 100 ether);
        vm.stopPrank();
        ILeveragedVault vault = ILeveragedVault(logris.vaults(daiVaultAddress));
        uint256 heldAssets = vault.heldAssets();
        assertEq(heldAssets, 100 ether);
        assertEq(vault.totalAssets(), 100 ether);
        assertGt(vault.balanceOf(user1), 0);
    }

    function testLeverageCall() public {
        logris.createVault(address(dai), daiVaultAddress);
        logris.whitelistAddress(address(this));
        vm.startPrank(user1);
        dai.approve(address(logris), 100 ether);
        logris.deposit(daiVaultAddress, 100 ether);
        vm.stopPrank();
        ILeveragedVault vault = ILeveragedVault(logris.vaults(daiVaultAddress));
        uint256 heldAssets = vault.heldAssets();
        vm.prank(user1);
        vault.leverage();
        console.log("heldAssets: %s", heldAssets);
        
    }
}
