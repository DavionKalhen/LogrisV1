// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/leveragers/BalancerCurveLeverager.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";

// fork specific
import "../src/interfaces/alchemist/Whitelist.sol";
import "../src/interfaces/alchemist/IAlchemistV2.sol";


contract DeployScript is Script {
    // partly figured out addresses for optimism
    /*address public wstETHAddress = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address public wETHAddress = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6; //duno
    address public alchemistV2Address = 0x654e16a0b161b150F5d1C8a5ba6E7A7B7760703A;*/
    // mainnet addresses
    address public wstETHAddress = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public wETHAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public alETHAddress = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address public alchemistV2Address = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    address eulerCallbackSender = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    LeveragedVault _vault;

    function setupForkSpecific(address leverager) public {
        IAlchemistV2 alchemist = IAlchemistV2(alchemistV2Address);

        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(wstETHAddress);
        console.log("old vault ceiling: ", params.maximumExpectedValue);
        vm.startPrank(alchemist.admin());
        alchemist.setMaximumExpectedValue(wstETHAddress, params.expectedValue + 1000 ether);
        params = alchemist.getYieldTokenParameters(wstETHAddress);
        console.log("new vault ceiling", params.maximumExpectedValue);

        uint newUnderlyingCapacity = params.maximumExpectedValue - params.expectedValue;
        console.log("vault capacity:", newUnderlyingCapacity);
        vm.stopPrank();
    }

    function leverageOnce() public {
        address user1 = vm.addr(1);
        vm.deal(user1, 200 ether);
        vm.startPrank(user1);
        _vault.depositUnderlying{value: 10 ether}();
        vm.stopPrank();
        console.log("vault balance:", _vault.balanceOf(user1));
        (uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) = _vault.getLeverageParameters();
        console.log("clampedDeposit:", clampedDeposit);
        console.log("flashLoanAmount:", flashLoanAmount);
        console.log("underlyingDepositMin:", underlyingDepositMin);
        console.log("mintAmount:", mintAmount);
        console.log("debtTradeMin:", debtTradeMin);
        _vault.leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    function run() public {
        // log block number
        console.log("block number:", block.number);
        vm.startBroadcast(); // Start a broadcast session
        BalancerCurveLeverager balancer_leverager = new BalancerCurveLeverager(wstETHAddress, wETHAddress, alETHAddress);
        //EulerCurveMetaLeverager euler_leverager = new EulerCurveMetaLeverager(wstETHAddress, wETHAddress, alETHAddress, eulerMarketsAddress, eulerCallbackSender);
        LeveragedVaultFactory factory = new LeveragedVaultFactory();
        address vault = factory.createVault(
            "WETH Leveraged ETH",
            "WETHLEV",
            wstETHAddress,
            wETHAddress,
            address(balancer_leverager),
            alchemistV2Address,
            100,
            300
        );

        console.log("vault address:", vault);
        console.log("leverager address:", address(balancer_leverager));

        _vault = LeveragedVault(vault);

        vm.stopBroadcast(); // End the broadcast session

        //setupForkSpecific(address(balancer_leverager));
        //leverageOnce();
        
    }
}