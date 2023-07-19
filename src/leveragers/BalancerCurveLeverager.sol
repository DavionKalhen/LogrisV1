// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./CurveLeverager.sol";
import "../interfaces/balancer/IFlashLoanRecipient.sol";
import "../interfaces/balancer/IVault.sol";
//import console log
import "forge-std/console.sol";

contract BalancerCurveLeverager is CurveLeverager, IFlashLoanRecipient{
    IVault vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    constructor(address _yieldToken,
    address _underlyingToken,
    address _debtToken)
    Leverager(_yieldToken, _underlyingToken, _debtToken) {
    }

    function _leverageWithFlashLoan(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin) internal override {
        (IERC20[] memory tokens, uint[] memory amounts) = _getFlashLoanParameters(flashLoanAmount);
        bytes memory data = abi.encode(msg.sender,
                                        true,
                                        clampedDeposit,
                                        flashLoanAmount,
                                        underlyingDepositMin,
                                        mintAmount,
                                        debtTradeMin);
        vault.flashLoan(this, tokens, amounts, data);
    }

    function _withdrawUnderlyingWithBurn(uint shares,
                                        uint flashLoanAmount,
                                        uint burnAmount,
                                        uint debtTradeMin,
                                        uint minUnderlyingOut) internal override {
        (IERC20[] memory tokens, uint[] memory amounts) = _getFlashLoanParameters(flashLoanAmount);
        bytes memory data = abi.encode(msg.sender,
                                        false,
                                        shares,
                                        flashLoanAmount,
                                        burnAmount,
                                        debtTradeMin,
                                        minUnderlyingOut);

        vault.flashLoan(this, tokens, amounts, data);
    }

    function _getFlashLoanParameters(uint flashLoanAmount) internal view returns (IERC20[] memory tokens,
                                                                                  uint[] memory amounts) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(underlyingToken);
        amounts = new uint[](1);
        amounts[0] = flashLoanAmount;
    }

    // so its really tricky having to have a contract receive the same callback signature with two different callback flows...
    // as luck would have it deposit and withdraw have the same number of parameters on their callback
    function receiveFlashLoan(IERC20[] memory,
                              uint256[] memory,
                              uint256[] memory,
                              bytes memory userData) external override {
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to the leverager
        require(msg.sender == address(vault));
        (address depositor,
         bool depositFlag,
         uint param1,
         uint param2,
         uint param3,
         uint param4,
         uint param5) = abi.decode(userData, (address, bool, uint, uint, uint, uint, uint));
        if(depositFlag) {
            _flashLoanDeposit(depositor, param1, param2, param3, param4, param5);
        } else {
            _flashLoanWithdraw(depositor, param1, param2, param3, param4, param5);
        }
    }
}