// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ILeveragerV3
/// @notice Generic leverager interface that works with any AlchemistV3 vault
/// @dev Leverager validates adapters via registry before executing operations
interface ILeveragerV3 {
    /// @notice Parameters for leverage operation
    struct LeverageParams {
        address vault;              // LeveragedVault to operate on
        address converter;          // ITokenConverter for underlying↔yield
        address flashLoanAdapter;   // Flash loan source
        address swapper;            // Debt↔underlying swapper
        uint256 depositAmount;      // User's initial deposit (yield tokens)
        uint256 flashLoanAmount;    // Amount to flash loan (underlying)
        uint256 mintAmount;         // Debt to mint
        uint256 minSwapOutput;      // Minimum swap output (slippage protection)
        uint256 minYieldOut;        // Minimum total yield from deposit + flash conversion
    }

    /// @notice Parameters for deleverage operation
    struct DeleverageParams {
        address vault;              // LeveragedVault to operate on
        address converter;          // ITokenConverter for underlying↔yield
        address flashLoanAdapter;   // Flash loan source
        address swapper;            // Debt↔underlying swapper
        address recipient;          // Recipient of underlying returned
        uint256 withdrawAmount;     // Yield tokens to withdraw
        uint256 flashLoanAmount;    // Amount to flash loan for repayment
        uint256 burnAmount;         // Debt to burn
        uint256 minOutput;          // Minimum output (slippage protection)
    }

    /// @notice Emitted when leverage is executed
    event LeverageExecuted(
        address indexed vault,
        address indexed user,
        uint256 depositAmount,
        uint256 flashLoanAmount,
        uint256 totalCollateral,
        uint256 debtMinted
    );

    /// @notice Emitted when deleverage is executed
    event DeleverageExecuted(
        address indexed vault,
        address indexed user,
        uint256 withdrawAmount,
        uint256 debtBurned,
        uint256 underlyingReturned
    );

    /// @notice Emitted when adapter approval changes
    event ConverterApprovalSet(address indexed converter, bool approved);
    event FlashLoanAdapterApprovalSet(address indexed adapter, bool approved);
    event SwapperApprovalSet(address indexed swapper, bool approved);

    /// @notice Execute leverage operation
    /// @param params Leverage parameters including vault, adapters, and amounts
    function leverage(LeverageParams calldata params) external;

    /// @notice Execute deleverage operation
    /// @param params Deleverage parameters including vault, adapters, and amounts
    function deleverage(DeleverageParams calldata params) external;

    /// @notice Check if a converter is approved
    function isApprovedConverter(address converter) external view returns (bool);

    /// @notice Check if a flash loan adapter is approved
    function isApprovedFlashLoanAdapter(address adapter) external view returns (bool);

    /// @notice Check if a swapper is approved
    function isApprovedSwapper(address swapper) external view returns (bool);

    /// @notice Set converter approval (admin only)
    function setConverterApproval(address converter, bool approved) external;

    /// @notice Set flash loan adapter approval (admin only)
    function setFlashLoanAdapterApproval(address adapter, bool approved) external;

    /// @notice Set swapper approval (admin only)
    function setSwapperApproval(address swapper, bool approved) external;
}
