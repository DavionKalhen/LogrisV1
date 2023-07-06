// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./Leverager.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
//import console log
import "forge-std/console.sol";

contract EulerCurveMetaLeverager is Leverager {
    address public flashLoanSender;//will be replaced by a calculation eventually

    constructor(address _yieldToken,
                address _underlyingToken,
                address _debtToken,
                address _flashLoan,
                address _flashLoanSender,
                address _debtSource,
                address _dex) 
    Leverager(_yieldToken, _underlyingToken, _debtToken, _flashLoan, _debtSource, _dex) {
        flashLoanSender = _flashLoanSender;
    }

    function leverage(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin) public override {
        require(clampedDeposit > 0, "Vault is full");
        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), clampedDeposit);

        if(flashLoanAmount == 0) {
            console.log("Basic deposit");
            _depositUnderlying(clampedDeposit, underlyingDepositMin, msg.sender);
        } else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            bytes memory data = abi.encode(msg.sender,
                                           flashLoanSender,
                                           true,
                                           clampedDeposit,
                                           flashLoanAmount,
                                           underlyingDepositMin,
                                           mintAmount,
                                           debtTradeMin);
            dToken.flashLoan(flashLoanAmount, data);
        }
        //the dust should get transmitted back to msg.sender but it might not be worth the gas...
    }

    // so its really tricky having to have a contract receive the same callback signature with two different callback flows...
    // as luck would have it deposit and withdraw have the same number of parameters on their callback
    function onFlashLoan(bytes memory data) external {
        (address sender,
         address _flashLoanSender,
         bool depositFlag,
         uint param1,
         uint param2,
         uint param3,
         uint param4,
         uint param5) = abi.decode(data, (address, address, bool, uint, uint, uint, uint, uint));
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to the leverager
        console.log("msg.sender:", msg.sender);
        console.log("sender:", sender);
        console.log("flashLoanSender:", _flashLoanSender);
        require(msg.sender == _flashLoanSender, "callback caller must be flashloan source");
        if(depositFlag) {
            _flashLoanDeposit(sender, param1, param2, param3, param4, param5);
        } else {
            _flashLoanWithdraw(sender, param1, param2, param3, param4, param5);
        }
    }

    function _getDTokenAddress() internal view returns (address dTokenAddress) {
        Markets markets = Markets(flashLoan);
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
    }


    function withdrawUnderlying(uint shares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut) public override {
        require(shares > 0, "must include shares to withdraw");
        require(shares <= getTotalWithdrawCapacity(msg.sender), "shares exceeds capacity");
        if(burnAmount == 0) {
            alchemist.withdrawUnderlyingFrom(msg.sender, yieldToken, shares, msg.sender, minUnderlyingOut);
        } else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            bytes memory data = abi.encode(msg.sender,
                                           flashLoanSender,
                                           false,
                                           shares,
                                           flashLoanAmount,
                                           burnAmount,
                                           debtTradeMin,
                                           minUnderlyingOut);
            dToken.flashLoan(flashLoanAmount, data);
        }
    }

}