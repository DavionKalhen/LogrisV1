pragma solidity ^0.8.0;

interface ICurveFactory {
    function get_best_rate(address, address, uint256) external view returns (address, uint256);
    function exchange(address _pool, address _from, address _to, uint256 _amount, uint256 _expected) external payable returns (uint256);
    function exchange(address _pool, address _from, address _to, uint256 _amount, uint256 _expected, address _receiver) external payable returns (uint256);
}