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
    address daiVaultAddress = 0xdA816459F1AB5631232FE5e97a05BBBb94970c95;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address alchemistV2Address = 0xde399d26ed46B7b509561f1B9B5Ad6cc1EBC7261;
    address iDAIAddress = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address uniswapv2RouterAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    IAlchemistV2 alchemist;
    LeveragedVault leveragedVault;
    iDAI dai;
    address user1;
    address daiOwner = 0xdDb108893104dE4E1C6d0E47c42237dB4E617ACc;
    IUniswapV2Router02 uniswap;
    Whitelist whitelist;

    function setUp() public {
        user1 = vm.addr(1);

        alchemist = IAlchemistV2(alchemistV2Address);
        address alchemixOwner = alchemist.admin();
        dai = iDAI(iDAIAddress);
        
        vm.deal(user1, 200 ether);
        address[] memory path = new address[](2);
        path[0] = wETHAddress;
        path[1] = iDAIAddress;
        uniswap = IUniswapV2Router02(uniswapv2RouterAddress);

        vm.prank(user1);
        uniswap.swapExactETHForTokens{value:10 ether}(1, path, user1, block.timestamp + 10000);
        assertGt(dai.balanceOf(user1), 100 ether);
        
        vm.prank(alchemixOwner);
        whitelist = new Whitelist();
        //you need to whitelist the leverager unless we're going with delegate call
        bytes32 b7 = bytes32(abi.encode(address(whitelist))); //works
        vm.store(address(alchemist), bytes32(uint256(11)), b7);
    }

    //this belongs in a leveragedVaultFactoryTest
    // function testCanCreateVault() public {
    //     address ret_vault = leveragedVaultFactory.createVault(address(dai), daiVaultAddress);
    //     address vault = leveragedVaultFactory.vaults(daiVaultAddress);
    //     assertEq(ret_vault, vault);
    // }

    // function testDepositToVault() public {
    //     leveragedVaultFactory.createVault(address(dai), daiVaultAddress);
    //     leveragedVaultFactory.whitelistAddress(address(this));
    //     vm.startPrank(user1);
    //     dai.approve(address(leveragedVaultFactory), 100 ether);
    //     leveragedVaultFactory.deposit(daiVaultAddress, 100 ether);
    //     vm.stopPrank();
    //     ILeveragedVault vault = ILeveragedVault(leveragedVaultFactory.vaults(daiVaultAddress));
    //     uint256 heldAssets = vault.getVaultRedeemableBalance();
    //     assertEq(heldAssets, 100 ether);
    // }

    // function testLeverageCall() public {
    //     leveragedVaultFactory.createVault(address(dai), daiVaultAddress);
    //     leveragedVaultFactory.whitelistAddress(address(this));
    //     vm.startPrank(user1);
    //     dai.approve(address(leveragedVaultFactory), 100 ether);
    //     leveragedVaultFactory.deposit(daiVaultAddress, 100 ether);
    //     vm.stopPrank();
    //     ILeveragedVault vault = ILeveragedVault(leveragedVaultFactory.vaults(daiVaultAddress));
    //     uint256 heldAssets = vault.getVaultRedeemableBalance();
    //     vm.prank(user1);
    //     vault.leverage();
    //     console.log("heldAssets: %s", heldAssets);
    // }
}
