// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

interface Markets {
    function underlyingToDToken(address underlying) external view returns (address);
}