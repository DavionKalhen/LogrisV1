import "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

pragma solidity ^0.8.0;

interface ILeveragedVault is IERC4626 {
    function heldAssets() external view returns (uint256);
    function leverage() external view;
}