// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title MainnetAddresses
 * @notice Centralized configuration for Ethereum mainnet contract addresses
 * @dev Used for fork testing and production deployment
 */
library MainnetAddresses {
    // ============ Flash Loan Providers ============

    /// @notice Balancer V2 Vault
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // ============ Standard Tokens ============

    /// @notice Wrapped Ether
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Wrapped stETH (Lido)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice stETH (Lido rebasing token)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice DAI Stablecoin
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    /// @notice USDC Stablecoin
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice USDT Stablecoin
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // ============ Alchemix V2 (Currently Deployed) ============

    /// @notice Alchemix alETH token
    address public constant ALETH = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;

    /// @notice Alchemix alUSD token (not used in this implementation)
    address public constant ALUSD = 0xBC6DA0FE9aD5f3b0d58160288917AA56653660E9;

    /// @notice Alchemix V2 alETH Alchemist
    address public constant ALCHEMIST_V2_ALETH = 0x062Bf725dC4cDF947aa79Ca2aaCCD4F385b13b5c;

    /// @notice WETH Transmuter Whitelist V2
    address public constant TRANSMUTER_WHITELIST_WETH = 0x211C74DB951c161c5A379363716EbDca5125EF59;

    // ============ Curve Pools ============

    /// @notice Curve alETH+ETH Factory Pool (LP token and swap)
    /// @dev This pool supports swapping between alETH and ETH
    address public constant CURVE_ALETH_ETH_POOL = 0xC4C319E2D4d66CcA4464C0c2B32c9Bd23ebe784e;

    /// @notice Curve alUSD Factory Pool (Metapool with 3Pool)
    address public constant CURVE_ALUSD_POOL = 0x43b4FdFD4Ff969587185cDB6f0BD875c5Fc83f8c;

    /// @notice Curve 3Pool (DAI/USDC/USDT)
    address public constant CURVE_3POOL = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // ============ Yearn Vaults ============

    /// @notice Yearn Curve alETH Vault
    address public constant YEARN_CURVE_ALETH = 0x718AbE90777F5B778B52D553a5aBaa148DD0dc5D;

    // ============ Alchemix V3 (Not Yet Deployed - Q2 2026) ============
    // Note: V3 addresses will be added after mainnet deployment
    // For now, fork tests deploy V3 contracts from source

    // ============ Chain Constants ============

    /// @notice Ethereum mainnet chain ID
    uint256 public constant CHAIN_ID = 1;

    /// @notice Approximate blocks per year on Ethereum
    uint256 public constant BLOCKS_PER_YEAR = 2_628_000; // ~12 sec blocks
}
