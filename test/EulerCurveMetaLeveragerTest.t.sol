pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../src/interfaces/ILeverager.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";
//import "../src/interfaces/alchemist/IAlchemistV2.sol";

contract EulerCurveMetaLeveragerTest is Test {
    address wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address alchemixV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    address alETHCurvePoolAddress = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    //i,j determined by coins view method on contract
    int128 ethPoolIndex = 0;
    int128 alETHPoolIndex = 1;
    ILeverager leverager;

    function setUp() public {
        vm.deal(address(this), 200 ether);
        leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, alchemixV2Address, alETHCurvePoolAddress, alETHPoolIndex, ethPoolIndex);
    }

    function testGetMethods() public {
        require(leverager.getYieldToken()==wstETHAddress);
        require(leverager.getUnderlyingToken()==wETHAddress);
        require(leverager.getDebtToken()==alETHAddress);
        require(leverager.getFlashLoan()==eulerMarketsAddress);
        require(leverager.getDebtSource()==alchemixV2Address);
        require(leverager.getDexPool()==alETHCurvePoolAddress);
    }

    function testGetDepositedBalance() public {
        address randomAccount = 0x2330eB2d92167c3b6B22690c03b508E0CA532980;
        uint256 yieldTokens = leverager.getDepositedBalance(randomAccount);
        require(yieldTokens > 0, "Deposit Balance lookup failed");
    }
    
    function testGetDebtBalance() public {
        address randomAccount = 0x2330eB2d92167c3b6B22690c03b508E0CA532980;
        int256 debtTokens = leverager.getDebtBalance(randomAccount);
        require(debtTokens > 0, "Debt Balance lookup failed");
    }

    function testGetRedeemableBalance() public {
        address randomAccount = 0xd24f5143605F79DF9D73E9b9b5969eD201B721A7;
        uint256 yieldTokens = leverager.getRedeemableBalance(randomAccount);
        require(yieldTokens > 0, "Redeemable Balance lookup failed");
    }
}