// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./CurveLeverager.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";

contract EulerCurveMetaLeverager is CurveLeverager {
    address public flashLoanSender;//will be replaced by a calculation eventually
    Markets markets;

    constructor(address _yieldToken,
                address _underlyingToken,
                address _debtToken,
                address _debtAdapter,
                address flashLoan,
                address _flashLoanSender) 
    Leverager(_yieldToken, _underlyingToken, _debtToken, _debtAdapter) {
        flashLoanSender = _flashLoanSender;
        markets = Markets(flashLoan);
    }

    /// @inheritdoc Leverager
    function _leverageWithFlashLoan(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin,
                      bytes memory swapParams) internal override {
        address dTokenAddress = _getDTokenAddress();
        DToken dToken = DToken(dTokenAddress);
        bytes memory data = abi.encode(msg.sender,
                                        flashLoanSender,
                                        true,
                                        clampedDeposit,
                                        flashLoanAmount,
                                        underlyingDepositMin,
                                        mintAmount,
                                        debtTradeMin,
                                        swapParams);
        dToken.flashLoan(flashLoanAmount, data);
    }

    /// @inheritdoc Leverager
    function _withdrawUnderlyingWithBurn(uint shares,
                                         uint flashLoanAmount,
                                         uint burnAmount,
                                         uint debtTradeMin,
                                         uint minUnderlyingOut,
                                         bytes memory swapParams) internal override {
        address dTokenAddress = _getDTokenAddress();
        DToken dToken = DToken(dTokenAddress);
        bytes memory data = abi.encode(msg.sender,
                                        flashLoanSender,
                                        false,
                                        shares,
                                        flashLoanAmount,
                                        burnAmount,
                                        debtTradeMin,
                                        minUnderlyingOut,
                                        swapParams);
        dToken.flashLoan(flashLoanAmount, data);
    }

    /**
        * @dev Callback function for flashloan. It will either deposit or withdraw depending on the data passed in.
        * @param data The data passed in from the flashloan call. depositFlag tells us if withdraw or deposit.
    */
    function onFlashLoan(bytes memory data) external {
        (address sender,
         address _flashLoanSender,
         bool depositFlag,
         uint param1,
         uint param2,
         uint param3,
         uint param4,
         uint param5,
         bytes memory params) = abi.decode(data, (address, address, bool, uint, uint, uint, uint, uint, bytes));
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to the leverager
        require(msg.sender == _flashLoanSender, "callback caller must be flashloan source");
        if(depositFlag) {
            _flashLoanDeposit(sender, param1, param2, param3, param4, param5, params);
        } else {
            _flashLoanWithdraw(sender, param1, param2, param3, param4, param5, params);
        }
    }

    function _getDTokenAddress() internal view returns (address dTokenAddress) {
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
    }
}