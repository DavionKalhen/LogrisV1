// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
/// @dev Uses registry pattern to approve adapters, shared across all vaults.
///      Deleverage uses AlchemistV3.repay() with yield tokens — fully deterministic, no DEX swap.
contract V3Leverager is ILeveragerV3, IFlashLoanCallback, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Flash Loan State ============

    /// @notice State machine for flash loan operations
    enum FlashLoanState {
        Idle,            // No flash loan in progress
        Leverage,        // Leverage operation in progress
        DeleverageRepay  // Repay-based deleverage in progress
    }

    // ============ Registries ============

    mapping(address => bool) private _approvedConverters;
    mapping(address => bool) private _approvedFlashLoanAdapters;
    mapping(address => bool) private _approvedSwappers;

    // ============ Flash Loan Context (transient storage via EIP-1153) ============

    /// @dev FlashLoanContext is kept as a memory struct for internal function signatures,
    ///      but backed by transient storage (tstore/tload) instead of regular storage.
    ///      Transient storage is automatically cleared after each transaction, eliminating
    ///      stale-state risks and saving ~20k gas per operation (no SSTORE cold writes).
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
        // Deleverage repay specific
        uint256 withdrawAmount;
        uint256 repayAmount;
    }

    // Transient storage slot offsets (base = keccak256("V3Leverager.transient") truncated)
    // Each field occupies one 32-byte slot at base + offset.
    uint256 private constant T_BASE     = uint256(keccak256("V3Leverager.transient"));
    uint256 private constant T_STATE           = T_BASE + 0;
    uint256 private constant T_VAULT           = T_BASE + 1;
    uint256 private constant T_CONVERTER       = T_BASE + 2;
    uint256 private constant T_SWAPPER         = T_BASE + 3;
    uint256 private constant T_FLASH_ADAPTER   = T_BASE + 4;
    uint256 private constant T_USER            = T_BASE + 5;
    uint256 private constant T_DEPOSIT_AMOUNT  = T_BASE + 6;
    uint256 private constant T_MINT_AMOUNT     = T_BASE + 7;
    uint256 private constant T_MIN_SWAP_OUTPUT = T_BASE + 8;
    uint256 private constant T_MIN_YIELD_OUT   = T_BASE + 9;
    uint256 private constant T_WITHDRAW_AMOUNT = T_BASE + 10;
    uint256 private constant T_REPAY_AMOUNT    = T_BASE + 11;

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
    error UnauthorizedCaller();

    // ============ Transient Storage Helpers ============

    /// @dev Write a uint256 value to a transient storage slot.
    function _tstore(uint256 slot, uint256 value) internal {
        assembly { tstore(slot, value) }
    }

    /// @dev Read a uint256 value from a transient storage slot.
    function _tload(uint256 slot) internal view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    /// @dev Write all FlashLoanContext fields to transient storage.
    function _storeContext(FlashLoanContext memory ctx) internal {
        _tstore(T_VAULT, uint256(uint160(ctx.vault)));
        _tstore(T_CONVERTER, uint256(uint160(ctx.converter)));
        _tstore(T_SWAPPER, uint256(uint160(ctx.swapper)));
        _tstore(T_FLASH_ADAPTER, uint256(uint160(ctx.flashLoanAdapter)));
        _tstore(T_USER, uint256(uint160(ctx.user)));
        _tstore(T_DEPOSIT_AMOUNT, ctx.depositAmount);
        _tstore(T_MINT_AMOUNT, ctx.mintAmount);
        _tstore(T_MIN_SWAP_OUTPUT, ctx.minSwapOutput);
        _tstore(T_MIN_YIELD_OUT, ctx.minYieldOut);
        _tstore(T_WITHDRAW_AMOUNT, ctx.withdrawAmount);
        _tstore(T_REPAY_AMOUNT, ctx.repayAmount);
    }

    /// @dev Read all FlashLoanContext fields from transient storage into memory.
    function _loadContext() internal view returns (FlashLoanContext memory ctx) {
        ctx.vault = address(uint160(_tload(T_VAULT)));
        ctx.converter = address(uint160(_tload(T_CONVERTER)));
        ctx.swapper = address(uint160(_tload(T_SWAPPER)));
        ctx.flashLoanAdapter = address(uint160(_tload(T_FLASH_ADAPTER)));
        ctx.user = address(uint160(_tload(T_USER)));
        ctx.depositAmount = _tload(T_DEPOSIT_AMOUNT);
        ctx.mintAmount = _tload(T_MINT_AMOUNT);
        ctx.minSwapOutput = _tload(T_MIN_SWAP_OUTPUT);
        ctx.minYieldOut = _tload(T_MIN_YIELD_OUT);
        ctx.withdrawAmount = _tload(T_WITHDRAW_AMOUNT);
        ctx.repayAmount = _tload(T_REPAY_AMOUNT);
    }

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Leverage ============

    /// @notice Execute a leverage operation using a flash loan and the vault's Alchemist position.
    /// @dev Pulls yield tokens from the caller, optionally flash-loans underlying, converts to yield,
    ///      deposits into the vault's position, mints debt, swaps debt to underlying, repays flash loan,
    ///      and returns surplus to the caller.
    /// @param params Struct containing vault, adapter addresses, amounts, and slippage limits.
    function leverage(LeverageParams calldata params) external nonReentrant {
        // Validate state (transient storage is 0/Idle at start of every tx)
        if (FlashLoanState(_tload(T_STATE)) != FlashLoanState.Idle) revert FlashLoanInProgress();
        if (msg.sender != params.vault) revert UnauthorizedCaller();

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

        // Store context for callback (transient storage)
        _storeContext(FlashLoanContext({
            vault: params.vault,
            converter: params.converter,
            swapper: params.swapper,
            flashLoanAdapter: params.flashLoanAdapter,
            // Keep leverage permissionless while preventing value extraction:
            // route any swap surplus back to the vault, not the external caller.
            user: params.vault,
            depositAmount: params.depositAmount,
            mintAmount: params.mintAmount,
            minSwapOutput: params.minSwapOutput,
            minYieldOut: params.minYieldOut,
            withdrawAmount: 0,
            repayAmount: 0
        }));

        // Set state before flash loan (transient)
        _tstore(T_STATE, uint256(FlashLoanState.Leverage));

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

        // Reset state after completion (transient storage auto-clears at tx end,
        // but reset explicitly for same-tx safety, e.g. multi-call scenarios)
        _tstore(T_STATE, uint256(FlashLoanState.Idle));
    }

    // ============ Deleverage (Repay-based) ============

    /// @notice Execute a repay-based deleverage: flash-loan underlying, convert to MYT, repay debt
    ///         with MYT, withdraw freed collateral, convert to underlying, repay flash loan.
    /// @dev No DEX swap needed — entire path is deterministic through VaultV2 deposit/redeem.
    ///      Cannot be called in the same block as leverage() due to CannotRepayOnMintBlock.
    /// @param params Struct containing vault, converter, flash loan adapter, and amounts.
    function deleverageRepay(DeleverageRepayParams calldata params) external nonReentrant {
        // Validate state (transient storage is 0/Idle at start of every tx)
        if (FlashLoanState(_tload(T_STATE)) != FlashLoanState.Idle) revert FlashLoanInProgress();
        if (msg.sender != params.vault) revert UnauthorizedCaller();

        // Validate approved adapters
        if (!_approvedConverters[params.converter]) revert UnapprovedConverter();
        if (!_approvedFlashLoanAdapters[params.flashLoanAdapter]) revert UnapprovedFlashLoanAdapter();

        // Deleverage always requires a flash loan
        if (params.flashLoanAmount == 0) revert FlashLoanRequired();

        ITokenConverter converter = ITokenConverter(params.converter);
        address underlyingToken = converter.underlyingToken();
        if (ILeveragedVault(params.vault).getUnderlyingToken() != underlyingToken) revert InvalidConverterTokens();

        if (!IFlashLoanAdapter(params.flashLoanAdapter).isTokenSupported(underlyingToken)) {
            revert UnsupportedFlashLoanToken();
        }

        // Store context for callback (transient storage)
        _storeContext(FlashLoanContext({
            vault: params.vault,
            converter: params.converter,
            swapper: address(0),           // Not needed for repay path
            flashLoanAdapter: params.flashLoanAdapter,
            user: params.recipient,
            depositAmount: 0,
            mintAmount: 0,
            minSwapOutput: params.minOutput,
            minYieldOut: 0,
            withdrawAmount: params.withdrawAmount,
            repayAmount: params.repayAmount
        }));

        // Set state before flash loan (transient)
        _tstore(T_STATE, uint256(FlashLoanState.DeleverageRepay));

        // Execute flash loan
        IFlashLoanAdapter(params.flashLoanAdapter).flashLoan(
            underlyingToken,
            params.flashLoanAmount,
            address(this),
            ""
        );

        // Reset state after completion (transient storage auto-clears at tx end,
        // but reset explicitly for same-tx safety)
        _tstore(T_STATE, uint256(FlashLoanState.Idle));
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
        FlashLoanState state = FlashLoanState(_tload(T_STATE));
        if (state == FlashLoanState.Idle) revert NotInFlashLoan();
        if (initiator != address(this)) revert InvalidCallback();

        FlashLoanContext memory ctx = _loadContext();
        if (msg.sender != ctx.flashLoanAdapter) revert InvalidCallback();

        if (state == FlashLoanState.Leverage) {
            return _handleLeverageCallback(ctx, token, amount, fee);
        } else {
            return _handleDeleverageRepayCallback(ctx, token, amount, fee);
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
        FlashLoanContext memory ctx = _loadContext();
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

        // 4-7: Mint, swap, repay, surplus. Skip when mintAmount == 0 (deposit-only mode:
        // Alchemist deposit capacity allows collateral but not enough for leverage).
        if (ctx.mintAmount > 0) {
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

    /// @dev Handles the flash loan callback during a repay-based deleverage operation.
    ///      Flow: convert underlying→MYT → repay debt → withdraw freed collateral → convert MYT→underlying
    function _handleDeleverageRepayCallback(
        FlashLoanContext memory ctx,
        address underlyingToken,
        uint256 flashLoanAmount,
        uint256 flashLoanFee
    ) internal returns (bool) {
        ITokenConverter converter = ITokenConverter(ctx.converter);
        ILeveragedVaultCallback vault = ILeveragedVaultCallback(ctx.vault);
        address yieldToken = converter.yieldToken();

        // 1. Convert flash-loaned underlying → MYT (deterministic via VaultV2)
        IERC20(underlyingToken).forceApprove(address(converter), flashLoanAmount);
        uint256 mytReceived = converter.toYield(flashLoanAmount, address(this), ctx.repayAmount);

        // 2. Repay debt with MYT
        IERC20(yieldToken).forceApprove(ctx.vault, ctx.repayAmount);
        vault.vaultRepayWithYieldTokens(ctx.repayAmount);

        // 3. Withdraw freed collateral (MYT)
        uint256 mytWithdrawn = vault.vaultWithdrawYieldTokens(ctx.withdrawAmount, address(this));

        // 4. Combine any leftover MYT from conversion + withdrawn collateral → convert all to underlying
        uint256 mytSurplus = mytReceived > ctx.repayAmount ? mytReceived - ctx.repayAmount : 0;
        uint256 totalMyt = mytWithdrawn + mytSurplus;
        IERC20(yieldToken).forceApprove(address(converter), totalMyt);
        uint256 underlyingReceived = converter.toUnderlying(totalMyt, address(this), 0);

        // 5. Repay flash loan
        uint256 flashRepayAmount = flashLoanAmount + flashLoanFee;
        if (underlyingReceived < flashRepayAmount) revert InsufficientOutput();
        IERC20(underlyingToken).safeTransfer(ctx.flashLoanAdapter, flashRepayAmount);

        // 6. Return surplus to user
        uint256 surplus = underlyingReceived - flashRepayAmount;
        if (surplus > 0) {
            IERC20(underlyingToken).safeTransfer(ctx.user, surplus);
        }

        // 7. Validate minimum output
        if (ctx.minSwapOutput > 0 && surplus < ctx.minSwapOutput) revert SlippageExceeded();

        emit DeleverageRepayExecuted(
            ctx.vault,
            ctx.user,
            ctx.repayAmount,
            ctx.withdrawAmount,
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
