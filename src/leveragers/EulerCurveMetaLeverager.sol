// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./CurveLeverager.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
//import console log
import "forge-std/console.sol";

contract EulerCurveMetaLeverager is CurveLeverager {
    address public flashLoanSender;//will be replaced by a calculation eventually
    Markets markets;

    constructor(address _yieldToken,
                address _underlyingToken,
                address _debtToken,
                address flashLoan,
                address _flashLoanSender) 
    Leverager(_yieldToken, _underlyingToken, _debtToken) {
        flashLoanSender = _flashLoanSender;
        markets = Markets(flashLoan);
    }

    function _leverageWithFlashLoan(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin) internal override {
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

    function _withdrawUnderlyingWithBurn(uint shares,
                                         uint flashLoanAmount,
                                         uint burnAmount,
                                         uint debtTradeMin,
                                         uint minUnderlyingOut) internal override {
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
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
    }

}