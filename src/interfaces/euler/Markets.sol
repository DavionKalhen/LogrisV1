// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.26;


struct AssetConfig {
    // Packed slot: 20 + 1 + 4 + 4 + 3 = 32
    address eTokenAddress;
    bool borrowIsolated;
    uint32 collateralFactor;
    uint32 borrowFactor;
    uint24 twapWindow;
}

interface Markets {
    function underlyingToDToken(address underlying) external view returns (address);
    function underlyingToEToken(address underlying) external view returns (address);
    function underlyingToAssetConfig(address underlying) external view returns (AssetConfig memory);
}