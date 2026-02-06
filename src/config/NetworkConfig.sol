// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title NetworkConfig
 * @notice Centralized configuration for network-specific addresses
 * @dev Use this library to avoid hardcoded addresses scattered across contracts
 */
library NetworkConfig {
    struct Config {
        address weth;
        address steth;
        address wsteth;
        address aleth;
        address curveStethPool;
        address curveAlethPool;
        address balancerVault;
        address aavePool;
    }

    /**
     * @notice Get Ethereum mainnet configuration
     * @return config Struct containing all mainnet addresses
     */
    function mainnet() internal pure returns (Config memory config) {
        config = Config({
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            steth: 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84,
            wsteth: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0,
            aleth: 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6,
            curveStethPool: 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022,
            curveAlethPool: 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e,
            balancerVault: 0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            aavePool: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
        });
    }

    // Individual address getters for convenience

    function getWETH() internal pure returns (address) {
        return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    }

    function getStETH() internal pure returns (address) {
        return 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    }

    function getWstETH() internal pure returns (address) {
        return 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    }

    function getAlETH() internal pure returns (address) {
        return 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    }

    function getCurveStETHPool() internal pure returns (address) {
        return 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    }

    function getCurveAlETHPool() internal pure returns (address) {
        return 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;
    }

    function getBalancerVault() internal pure returns (address) {
        return 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    }

    function getAaveV3Pool() internal pure returns (address) {
        return 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    }
}
