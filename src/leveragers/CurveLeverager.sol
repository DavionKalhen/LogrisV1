// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/curve/ICurveFactory.sol";
import "../interfaces/wETH/IWETH.sol";
import "./Leverager.sol";

abstract contract CurveLeverager is Leverager {
    address constant dex = 0x99a58482BD75cbab83b27EC03CA68fF489b5788f;
    address constant curveEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function _swapDebtTokens(uint amount, uint minAmountOut) internal override {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapTo = underlyingToken == weth ? curveEth : underlyingToken;
        
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(debtToken, swapTo, amount);
        require(amountOut >= minAmountOut, "CurveSwapper: Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmountOut, address(this));
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _swapToDebtTokens(uint amount, uint minAmountOut) internal override {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapFrom = underlyingToken;
        if(underlyingToken == weth) {
            swapFrom = curveEth;
            IWETH(weth).withdraw(amount);
        }

        (address pool, uint256 amountOut) = curveFactory.get_best_rate(swapFrom, debtToken, amount);
        require(amountOut >= minAmountOut, "CurveSwapper: Swap exceeds max acceptable loss");
        uint amountReceived = curveFactory.exchange{value:amount}(pool, swapFrom, debtToken, amount, minAmountOut);
        emit Swap(underlyingToken, debtToken, amount, amountReceived);
    }
}
