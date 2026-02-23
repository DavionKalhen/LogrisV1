// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

struct AddressInfo {
    address addr;
    string description;
    uint256 version;
    uint256 last_modified;
}

interface ICurveAddressProvider {
    function get_id_info(uint256 id) external view returns (AddressInfo memory);
}