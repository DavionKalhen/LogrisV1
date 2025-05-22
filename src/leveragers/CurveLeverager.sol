// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/curve/ICurveAddressProvider.sol";
import "../interfaces/curve/ICurveRouter.sol";

import "../interfaces/wETH/IWETH.sol";
import "./Leverager.sol";

abstract contract CurveLeverager is Leverager {
    ICurveAddressProvider constant curveMetaRegistry = ICurveAddressProvider(0x5ffe7FB82894076ECB99A30D6A32e969e6e35E98);
    
    /// @inheritdoc Leverager
    function _swapDebtTokens(uint amount, uint minAmountOut, bytes memory swapParams) internal override {
        ICurveRouter router = ICurveRouter(curveMetaRegistry.get_id_info(2).addr);
        CurveRouterParams memory params = abi.decode(swapParams, (CurveRouterParams));
        IERC20(debtToken).approve(address(router), amount);
        uint256 amountReceived = router.exchange(params._route, params._swap_params, amount, minAmountOut);
        
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    /// @inheritdoc Leverager
    function _swapToDebtTokens(uint amount, uint minAmountOut, bytes memory swapParams) internal override {
        ICurveRouter router = ICurveRouter(curveMetaRegistry.get_id_info(2).addr);
        CurveRouterParams memory params = abi.decode(swapParams, (CurveRouterParams));
        IERC20(underlyingToken).approve(address(router), amount);
        uint256 amountReceived = router.exchange(params._route, params._swap_params, amount, minAmountOut);
        emit Swap(underlyingToken, debtToken, amount, amountReceived);
    }
}
