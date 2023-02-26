// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IAlchemixV1Leverage {
    event Leverage(address indexed user, address indexed token, uint256 amount);

    function leverage(address token, uint256 amount) external;
    function vault() external returns(address);
}