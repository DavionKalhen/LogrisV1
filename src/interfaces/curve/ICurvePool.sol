pragma solidity ^0.8.0;

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns(uint256);
}