pragma solidity ^0.8.0;

interface iDAI {
        function mint(address usr, uint wad) external;
        function balanceOf(address usr) external view returns (uint);
        function decimals() external view returns (uint8);
        function approve(address usr, uint wad) external returns (bool);
}