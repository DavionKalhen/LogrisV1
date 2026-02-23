// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    /// @notice Parameters for repay-based deleverage (no DEX swap needed)
    /// @dev Uses AlchemistV3.repay() with yield tokens instead of burn() with debt tokens.
    ///      The entire path is deterministic through VaultV2 deposit/redeem.
    struct DeleverageRepayParams {
        address vault;              // LeveragedVault to operate on
        address converter;          // ITokenConverter for underlying↔MYT (deterministic)
        address flashLoanAdapter;   // Flash loan source
        address recipient;          // Recipient of underlying returned
        uint256 withdrawAmount;     // MYT to withdraw after repay frees collateral
        uint256 flashLoanAmount;    // Underlying to flash loan
        uint256 repayAmount;        // MYT to repay with (converted from flash loan)
        uint256 minOutput;          // Minimum underlying returned to recipient
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

    /// @notice Emitted when repay-based deleverage is executed
    event DeleverageRepayExecuted(
        address indexed vault,
        address indexed user,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 underlyingReturned
    );

    /// @notice Emitted when adapter approval changes
    event ConverterApprovalSet(address indexed converter, bool approved);
    event FlashLoanAdapterApprovalSet(address indexed adapter, bool approved);
    event SwapperApprovalSet(address indexed swapper, bool approved);

    /// @notice Execute leverage operation
    /// @param params Leverage parameters including vault, adapters, and amounts
    function leverage(LeverageParams calldata params) external;

    /// @notice Execute repay-based deleverage operation (no DEX swap)
    /// @dev Cannot be called in the same block as leverage() due to CannotRepayOnMintBlock.
    ///      Access control: msg.sender must equal params.vault (only the vault can initiate deleverage).
    /// @param params Deleverage parameters including vault, converter, and amounts
    function deleverageRepay(DeleverageRepayParams calldata params) external;

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
