// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct CurveRouterParams {
    address[11] _route;
    uint256[5][5] _swap_params;
}

interface ICurveRouter {
    function exchange(address[11] memory _route, uint256[5][5] memory _swap_params, uint256 amount, uint256 _min_dy) payable external returns (uint256 dy);
}