// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ILeveragerV3.sol";
import "../interfaces/ITokenConverter.sol";
import "../interfaces/ISwapper.sol";
import "../interfaces/ILeveragedVault.sol";
import "../interfaces/ILeveragedVaultCallback.sol";
import "../interfaces/flashloan/IFlashLoanAdapter.sol";
import "../interfaces/flashloan/IFlashLoanCallback.sol";
import "../../alchemix-v3/src/interfaces/IAlchemistV3.sol";

/// @notice Minimal interface for vault's alchemist getter
interface ILeveragedVaultAlchemist {
    function alchemist() external view returns (IAlchemistV3);
}
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title V3Leverager
/// @notice Generic leverager that works with any AlchemistV3 vault
/// @dev Uses registry pattern to approve adapters, shared across all vaults
contract V3Leverager is ILeveragerV3, IFlashLoanCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Flash Loan State ============

    /// @notice State machine for flash loan operations
    enum FlashLoanState {
        Idle,       // No flash loan in progress
        Leverage,   // Leverage operation in progress
        Deleverage  // Deleverage operation in progress
    }

    // ============ Registries ============

    mapping(address => bool) private _approvedConverters;
    mapping(address => bool) private _approvedFlashLoanAdapters;
    mapping(address => bool) private _approvedSwappers;

    // ============ Flash Loan Context ============

    struct FlashLoanContext {
        address vault;
        address converter;
        address swapper;
        address flashLoanAdapter;
        address user;
        uint256 depositAmount;
        uint256 mintAmount;
        uint256 minSwapOutput;
        uint256 minYieldOut;
        // Deleverage specific
        uint256 withdrawAmount;
        uint256 burnAmount;
    }

    FlashLoanContext private _context;
    FlashLoanState private _state;

    // ============ Errors ============

    error UnapprovedConverter();
    error UnapprovedFlashLoanAdapter();
    error UnapprovedSwapper();
    error InvalidCallback();
    error InsufficientOutput();
    error FlashLoanInProgress();
    error NotInFlashLoan();
    error SlippageExceeded();
    error UnsupportedFlashLoanToken();
    error InvalidConverterTokens();
    error FlashLoanRequired();

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Leverage ============

    /// @notice Execute a leverage operation using a flash loan and the vault's Alchemist position.
    /// @dev Pulls yield tokens from the caller, optionally flash-loans underlying, converts to yield,
    ///      deposits into the vault's position, mints debt, swaps debt to underlying, repays flash loan,
    ///      and returns surplus to the caller.
    /// @param params Struct containing vault, adapter addresses, amounts, and slippage limits.
    function leverage(LeverageParams calldata params) external nonReentrant {
        // Validate state
        if (_state != FlashLoanState.Idle) revert FlashLoanInProgress();

        // Validate approved adapters
        if (!_approvedConverters[params.converter]) revert UnapprovedConverter();
        if (!_approvedFlashLoanAdapters[params.flashLoanAdapter]) revert UnapprovedFlashLoanAdapter();
        if (!_approvedSwappers[params.swapper]) revert UnapprovedSwapper();

        ITokenConverter converter = ITokenConverter(params.converter);
        address yieldToken = converter.yieldToken();
        address underlyingToken = converter.underlyingToken();
        if (ILeveragedVault(params.vault).getYieldToken() != yieldToken) revert InvalidConverterTokens();
        if (ILeveragedVault(params.vault).getUnderlyingToken() != underlyingToken) revert InvalidConverterTokens();

        // Pull user's deposit (yield tokens)
        if (params.depositAmount > 0) {
            IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), params.depositAmount);
        }

        // Store context for callback
        _context = FlashLoanContext({
            vault: params.vault,
            converter: params.converter,
            swapper: params.swapper,
            flashLoanAdapter: params.flashLoanAdapter,
            user: msg.sender,
            depositAmount: params.depositAmount,
            mintAmount: params.mintAmount,
            minSwapOutput: params.minSwapOutput,
            minYieldOut: params.minYieldOut,
            withdrawAmount: 0,
            burnAmount: 0
        });

        // Set state before flash loan
        _state = FlashLoanState.Leverage;

        if (params.flashLoanAmount > 0) {
            if (!IFlashLoanAdapter(params.flashLoanAdapter).isTokenSupported(underlyingToken)) {
                revert UnsupportedFlashLoanToken();
            }
            // Execute flash loan - callback will handle the leverage logic
            IFlashLoanAdapter(params.flashLoanAdapter).flashLoan(
                underlyingToken,
                params.flashLoanAmount,
                address(this),
                ""
            );
        } else {
            // No flash loan needed - execute leverage logic directly
            _executeLeverageLogic(underlyingToken, 0, 0);
        }

        // Reset state after completion
        _state = FlashLoanState.Idle;
        delete _context;
    }

    // ============ Deleverage ============

    /// @notice Execute a deleverage operation: flash-loan underlying, swap to debt, burn debt,
    ///         withdraw collateral, convert to underlying, repay flash loan, send surplus underlying
    ///         and any excess debt tokens to recipient.
    /// @param params Struct containing vault, adapter addresses, amounts, and slippage limits.
    function deleverage(DeleverageParams calldata params) external nonReentrant {
        // Validate state
        if (_state != FlashLoanState.Idle) revert FlashLoanInProgress();

        // Validate approved adapters
        if (!_approvedConverters[params.converter]) revert UnapprovedConverter();
        if (!_approvedFlashLoanAdapters[params.flashLoanAdapter]) revert UnapprovedFlashLoanAdapter();
        if (!_approvedSwappers[params.swapper]) revert UnapprovedSwapper();

        // Deleverage always requires a flash loan (to swap to debt tokens for burning)
        if (params.flashLoanAmount == 0) revert FlashLoanRequired();

        ITokenConverter converter = ITokenConverter(params.converter);
        address underlyingToken = converter.underlyingToken();
        if (ILeveragedVault(params.vault).getUnderlyingToken() != underlyingToken) revert InvalidConverterTokens();

        if (!IFlashLoanAdapter(params.flashLoanAdapter).isTokenSupported(underlyingToken)) {
            revert UnsupportedFlashLoanToken();
        }

        // Store context for callback
        _context = FlashLoanContext({
            vault: params.vault,
            converter: params.converter,
            swapper: params.swapper,
            flashLoanAdapter: params.flashLoanAdapter,
            user: params.recipient,
            depositAmount: 0,
            mintAmount: 0,
            minSwapOutput: params.minOutput,
            minYieldOut: 0,
            withdrawAmount: params.withdrawAmount,
            burnAmount: params.burnAmount
        });

        // Set state before flash loan
        _state = FlashLoanState.Deleverage;

        // Execute flash loan
        IFlashLoanAdapter(params.flashLoanAdapter).flashLoan(
            underlyingToken,
            params.flashLoanAmount,
            address(this),
            ""
        );

        // Reset state after completion
        _state = FlashLoanState.Idle;
        delete _context;
    }

    // ============ Flash Loan Callback ============

    /// @notice Callback invoked by the flash loan adapter after funds are received.
    /// @dev Routes to leverage or deleverage handler based on the current state machine state.
    /// @param initiator The address that initiated the flash loan (must be this contract).
    /// @param token The flash-loaned token address.
    /// @param amount The flash-loaned amount.
    /// @param fee The flash loan fee to repay.
    /// @return True if the callback executed successfully.
    function onFlashLoanReceived(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external returns (bool) {
        // Validate callback - must be in an active flash loan state
        if (_state == FlashLoanState.Idle) revert NotInFlashLoan();
        if (initiator != address(this)) revert InvalidCallback();
        if (msg.sender != _context.flashLoanAdapter) revert InvalidCallback();

        FlashLoanContext memory ctx = _context;

        if (_state == FlashLoanState.Leverage) {
            return _handleLeverageCallback(ctx, token, amount, fee);
        } else {
            return _handleDeleverageCallback(ctx, token, amount, fee);
        }
    }

    /// @dev Handles the flash loan callback during a leverage operation.
    function _handleLeverageCallback(
        FlashLoanContext memory ctx,
        address underlyingToken,
        uint256 flashLoanAmount,
        uint256 flashLoanFee
    ) internal returns (bool) {
        _executeLeverageLogic(underlyingToken, flashLoanAmount, flashLoanFee);
        return true;
    }

    /// @dev Core leverage logic - can be called from callback or directly (when no flash loan)
    function _executeLeverageLogic(
        address underlyingToken,
        uint256 flashLoanAmount,
        uint256 flashLoanFee
    ) internal {
        FlashLoanContext memory ctx = _context;
        ITokenConverter converter = ITokenConverter(ctx.converter);
        ILeveragedVaultCallback vault = ILeveragedVaultCallback(ctx.vault);
        address yieldToken = converter.yieldToken();

        uint256 convertedYield = 0;

        // 1. Convert flash-loaned underlying → yield tokens (if any)
        if (flashLoanAmount > 0) {
            IERC20(underlyingToken).forceApprove(address(converter), flashLoanAmount);
            uint256 minYieldFromFlash = ctx.minYieldOut > ctx.depositAmount
                ? ctx.minYieldOut - ctx.depositAmount
                : 0;
            convertedYield = converter.toYield(flashLoanAmount, address(this), minYieldFromFlash);
        }

        // 2. Combine with user's deposit
        uint256 totalYield = ctx.depositAmount + convertedYield;
        if (ctx.minYieldOut > 0 && totalYield < ctx.minYieldOut) revert SlippageExceeded();

        // 3. Deposit yield tokens to vault → AlchemistV3
        IERC20(yieldToken).forceApprove(ctx.vault, totalYield);
        vault.vaultDepositYieldTokens(totalYield);

        // 4. Mint debt tokens
        vault.vaultMintDebtTokens(ctx.mintAmount, address(this));

        // 5. Swap debt → underlying
        address debtToken = _getDebtToken(ctx.vault);
        IERC20(debtToken).forceApprove(ctx.swapper, ctx.mintAmount);
        uint256 swapOutput = ISwapper(ctx.swapper).swapDebtToUnderlying(
            ctx.mintAmount,
            ctx.minSwapOutput,
            address(this),
            ""
        );

        // Validate slippage protection
        if (swapOutput < ctx.minSwapOutput) revert SlippageExceeded();

        // 6. Repay flash loan (if any)
        uint256 repayAmount = flashLoanAmount + flashLoanFee;
        if (repayAmount > 0) {
            if (swapOutput < repayAmount) revert InsufficientOutput();
            IERC20(underlyingToken).safeTransfer(ctx.flashLoanAdapter, repayAmount);
        }

        // 7. Return surplus to user
        uint256 surplus = swapOutput > repayAmount ? swapOutput - repayAmount : 0;
        if (surplus > 0) {
            IERC20(underlyingToken).safeTransfer(ctx.user, surplus);
        }

        emit LeverageExecuted(
            ctx.vault,
            ctx.user,
            ctx.depositAmount,
            flashLoanAmount,
            totalYield,
            ctx.mintAmount
        );
    }

    /// @dev Handles the flash loan callback during a deleverage operation.
    function _handleDeleverageCallback(
        FlashLoanContext memory ctx,
        address underlyingToken,
        uint256 flashLoanAmount,
        uint256 flashLoanFee
    ) internal returns (bool) {
        ITokenConverter converter = ITokenConverter(ctx.converter);
        ILeveragedVaultCallback vault = ILeveragedVaultCallback(ctx.vault);
        address yieldToken = converter.yieldToken();
        address debtToken = _getDebtToken(ctx.vault);

        // 1. Swap underlying → debt tokens
        IERC20(underlyingToken).forceApprove(ctx.swapper, flashLoanAmount);
        uint256 debtReceived = ISwapper(ctx.swapper).swapUnderlyingToDebt(
            flashLoanAmount,
            ctx.burnAmount,
            address(this),
            ""
        );
        if (debtReceived < ctx.burnAmount) revert SlippageExceeded();

        // 2. Burn only the required debt tokens; return surplus to user
        IERC20(debtToken).forceApprove(ctx.vault, ctx.burnAmount);
        vault.vaultBurnDebtTokens(ctx.burnAmount);
        uint256 debtSurplus = debtReceived - ctx.burnAmount;
        if (debtSurplus > 0) {
            IERC20(debtToken).safeTransfer(ctx.user, debtSurplus);
        }

        // 3. Withdraw yield tokens (use actual withdrawn amount)
        uint256 yieldWithdrawn = vault.vaultWithdrawYieldTokens(ctx.withdrawAmount, address(this));

        // 4. Convert yield → underlying
        IERC20(yieldToken).forceApprove(address(converter), yieldWithdrawn);
        uint256 underlyingReceived = converter.toUnderlying(
            yieldWithdrawn,
            address(this),
            ctx.minSwapOutput
        );

        // Validate slippage protection
        if (underlyingReceived < ctx.minSwapOutput) revert SlippageExceeded();

        // 5. Repay flash loan
        uint256 repayAmount = flashLoanAmount + flashLoanFee;
        if (underlyingReceived < repayAmount) revert InsufficientOutput();

        IERC20(underlyingToken).safeTransfer(ctx.flashLoanAdapter, repayAmount);

        // 6. Return surplus to user
        uint256 surplus = underlyingReceived - repayAmount;
        if (surplus > 0) {
            IERC20(underlyingToken).safeTransfer(ctx.user, surplus);
        }

        emit DeleverageExecuted(
            ctx.vault,
            ctx.user,
            yieldWithdrawn,
            debtReceived,
            surplus
        );

        return true;
    }

    // ============ Internal Helpers ============

    /// @dev Reads the debt token address from the vault's Alchemist.
    function _getDebtToken(address vault) internal view returns (address) {
        IAlchemistV3 alchemist = ILeveragedVaultAlchemist(vault).alchemist();
        return alchemist.debtToken();
    }

    // ============ Admin Functions ============

    /// @notice Approve or revoke a token converter for use in leverage/deleverage operations.
    /// @param converter The converter address.
    /// @param approved True to approve, false to revoke.
    function setConverterApproval(address converter, bool approved) external onlyOwner {
        _approvedConverters[converter] = approved;
        emit ConverterApprovalSet(converter, approved);
    }

    /// @notice Approve or revoke a flash loan adapter.
    /// @param adapter The flash loan adapter address.
    /// @param approved True to approve, false to revoke.
    function setFlashLoanAdapterApproval(address adapter, bool approved) external onlyOwner {
        _approvedFlashLoanAdapters[adapter] = approved;
        emit FlashLoanAdapterApprovalSet(adapter, approved);
    }

    /// @notice Approve or revoke a debt-token swapper.
    /// @param swapper The swapper address.
    /// @param approved True to approve, false to revoke.
    function setSwapperApproval(address swapper, bool approved) external onlyOwner {
        _approvedSwappers[swapper] = approved;
        emit SwapperApprovalSet(swapper, approved);
    }

    /// @notice Batch-approve multiple converters, flash loan adapters, and swappers in one call.
    /// @param converters Array of converter addresses to approve.
    /// @param flashLoanAdapters Array of flash loan adapter addresses to approve.
    /// @param swappers Array of swapper addresses to approve.
    function batchApprove(
        address[] calldata converters,
        address[] calldata flashLoanAdapters,
        address[] calldata swappers
    ) external onlyOwner {
        for (uint256 i = 0; i < converters.length;) {
            _approvedConverters[converters[i]] = true;
            emit ConverterApprovalSet(converters[i], true);
            unchecked { ++i; }
        }
        for (uint256 i = 0; i < flashLoanAdapters.length;) {
            _approvedFlashLoanAdapters[flashLoanAdapters[i]] = true;
            emit FlashLoanAdapterApprovalSet(flashLoanAdapters[i], true);
            unchecked { ++i; }
        }
        for (uint256 i = 0; i < swappers.length;) {
            _approvedSwappers[swappers[i]] = true;
            emit SwapperApprovalSet(swappers[i], true);
            unchecked { ++i; }
        }
    }

    // ============ View Functions ============

    /// @notice Returns whether a converter is approved for use.
    /// @param converter The converter address to check.
    /// @return True if approved.
    function isApprovedConverter(address converter) external view returns (bool) {
        return _approvedConverters[converter];
    }

    /// @notice Returns whether a flash loan adapter is approved for use.
    /// @param adapter The adapter address to check.
    /// @return True if approved.
    function isApprovedFlashLoanAdapter(address adapter) external view returns (bool) {
        return _approvedFlashLoanAdapters[adapter];
    }

    /// @notice Returns whether a swapper is approved for use.
    /// @param swapper The swapper address to check.
    /// @return True if approved.
    function isApprovedSwapper(address swapper) external view returns (bool) {
        return _approvedSwappers[swapper];
    }
}
