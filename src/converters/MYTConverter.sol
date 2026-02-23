// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/ITokenConverter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal ERC4626 interface for VaultV2 deposit/redeem + view conversions.
interface IVaultV2ERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title MYTConverter
/// @notice Converts between underlying tokens and MYT (VaultV2 shares) via ERC4626 deposit/redeem
/// @dev Fully deterministic — no DEX interaction, no slippage from external markets.
///      VaultV2 deposit/redeem are 1:1 accounting operations (share price reflects yield accrual).
contract MYTConverter is ITokenConverter {
    using SafeERC20 for IERC20;

    error InsufficientYieldOutput();
    error InsufficientUnderlyingOutput();
    error ZeroAddress();

    event ConvertedToYield(uint256 underlyingAmount, uint256 mytAmount, address indexed recipient);
    event ConvertedToUnderlying(uint256 mytAmount, uint256 underlyingAmount, address indexed recipient);

    IVaultV2ERC4626 public immutable VAULT_V2;
    address public immutable UNDERLYING;

    /// @param _vaultV2 The VaultV2 (MYT) ERC4626 vault address
    /// @param _underlying The underlying token address (e.g., WETH)
    constructor(address _vaultV2, address _underlying) {
        if (_vaultV2 == address(0)) revert ZeroAddress();
        if (_underlying == address(0)) revert ZeroAddress();
        VAULT_V2 = IVaultV2ERC4626(_vaultV2);
        UNDERLYING = _underlying;
    }

    /// @inheritdoc ITokenConverter
    function yieldToken() external view override returns (address) {
        return address(VAULT_V2);
    }

    /// @inheritdoc ITokenConverter
    function underlyingToken() external view override returns (address) {
        return UNDERLYING;
    }

    /// @notice Convert underlying to MYT via VaultV2 deposit
    /// @dev underlying → VaultV2.deposit() → MYT shares
    function toYield(
        uint256 amount,
        address recipient,
        uint256 minYieldOut
    ) external override returns (uint256 mytAmount) {
        IERC20(UNDERLYING).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(UNDERLYING).forceApprove(address(VAULT_V2), amount);
        mytAmount = VAULT_V2.deposit(amount, recipient);
        if (mytAmount < minYieldOut) revert InsufficientYieldOutput();

        emit ConvertedToYield(amount, mytAmount, recipient);
    }

    /// @notice Convert MYT to underlying via VaultV2 redeem
    /// @dev MYT shares → VaultV2.redeem() → underlying
    function toUnderlying(
        uint256 amount,
        address recipient,
        uint256 minUnderlyingOut
    ) external override returns (uint256 underlyingAmount) {
        IERC20(address(VAULT_V2)).safeTransferFrom(msg.sender, address(this), amount);
        underlyingAmount = VAULT_V2.redeem(amount, recipient, address(this));
        if (underlyingAmount < minUnderlyingOut) revert InsufficientUnderlyingOutput();

        emit ConvertedToUnderlying(amount, underlyingAmount, recipient);
    }

    /// @inheritdoc ITokenConverter
    function previewToYield(uint256 amount) external view override returns (uint256) {
        return VAULT_V2.convertToShares(amount);
    }

    /// @inheritdoc ITokenConverter
    function previewToUnderlying(uint256 amount) external view override returns (uint256) {
        return VAULT_V2.convertToAssets(amount);
    }
}
