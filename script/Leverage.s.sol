// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/leveragers/BalancerCurveLeverager.sol";
import "../src/leveragers/EulerCurveMetaLeverager.sol";

// fork specific
import "../src/interfaces/alchemist/Whitelist.sol";
import "../src/interfaces/alchemist/IAlchemistV2.sol";


contract Leverage is Script {
    LeveragedVault _vault = LeveragedVault(0xdB4471Db5086A62e04792DEe618f6bDE9a8A25d9);

    function run() public {
        // log block number
        console.log("block number:", block.number);
        console.log("sender:", msg.sender);
        vm.startBroadcast(); // Start a broadcast session
        //console.log("vault balance:", _vault.balanceOf(user1));
        (uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) = _vault.getLeverageParameters();
        console.log("clampedDeposit:", clampedDeposit);
        console.log("flashLoanAmount:", flashLoanAmount);
        console.log("underlyingDepositMin:", underlyingDepositMin);
        console.log("mintAmount:", mintAmount);
        console.log("debtTradeMin:", debtTradeMin);
        _vault.leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
        
        vm.stopBroadcast(); // End the broadcast session
    }
}