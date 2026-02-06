// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

interface IAlchemistV3Position is IERC721 {
    function alchemist() external view returns (address);
    function mint(address to) external returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
} 