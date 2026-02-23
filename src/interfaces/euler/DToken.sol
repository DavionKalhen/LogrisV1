// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.28;

interface DToken {
    function flashLoan(uint amount, bytes calldata data) external;
}