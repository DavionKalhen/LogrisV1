pragma solidity ^0.8.0;

interface ICurveSwap {
    function exchange_with_best_rate(address, address, uint256, uint256, address) external returns(uint256);
    function get_best_rate(address, address, uint256) external view returns (address, uint256);
}