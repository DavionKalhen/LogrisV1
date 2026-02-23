// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/flashloan/IFlashLoanAdapter.sol";
import "../../interfaces/flashloan/IFlashLoanCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @notice Aave V3 Pool interface (minimal)
interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

/// @notice Aave V3 flash loan receiver interface
interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/**
 * @title AaveV3FlashLoanAdapter
 * @notice Flash loan adapter for Aave V3 Pool
 * @dev Aave V3 charges a 0.05% fee (5 bps) for flash loans
 *
 * Key differences from Balancer:
 * - Has a fee (0.05%)
 * - Uses flashLoanSimple for single asset
 * - Larger liquidity pool
 */
contract AaveV3FlashLoanAdapter is IFlashLoanAdapter, IFlashLoanSimpleReceiver, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    /// @notice Aave V3 Pool address (Ethereum mainnet)
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    /// @notice The Aave Pool contract
    IAaveV3Pool public immutable AAVE_POOL;

    /// @notice Flash loan in progress flag
    bool private _flashLoanInProgress;

    /// @notice Context storage for callback
    struct FlashLoanContext {
        address initiator;
        address recipient;
        address token;
        uint256 amount;
    }
    FlashLoanContext private _context;

    /// @notice Emitted when emergency withdrawal occurs
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Errors
    error ContextNotInitialized();
    error InvalidToken();
    error InvalidCaller();
    error InvalidInitiator();
    error TokenMismatch();
    error AmountMismatch();

    /**
     * @notice Constructor
     * @param _aavePool Optional custom pool address (uses mainnet default if zero)
     */
    constructor(address _aavePool) Ownable(msg.sender) {
        AAVE_POOL = IAaveV3Pool(_aavePool == address(0) ? AAVE_V3_POOL : _aavePool);
    }

    /// @inheritdoc IFlashLoanAdapter
    function flashLoan(
        address token,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external override nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidRecipient();
        if (token == address(0)) revert InvalidToken();

        // Mark flash loan as in progress
        _flashLoanInProgress = true;

        // Store context for callback validation
        _context = FlashLoanContext({
            initiator: msg.sender,
            recipient: recipient,
            token: token,
            amount: amount
        });

        // Execute flash loan through Aave V3 Pool
        AAVE_POOL.flashLoanSimple(
            address(this),  // receiver
            token,
            amount,
            data,
            0               // referral code
        );

        // Clear state after completion
        _flashLoanInProgress = false;
        delete _context;
    }

    /**
     * @notice Aave V3 flash loan callback
     * @dev Called by Aave Pool during flash loan execution
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        // SECURITY: Verify caller is Aave Pool
        if (msg.sender != address(AAVE_POOL)) revert InvalidCaller();

        // SECURITY: Verify flash loan is in progress
        if (!_flashLoanInProgress) revert ContextNotInitialized();

        // SECURITY: Verify initiator is this contract
        if (initiator != address(this)) revert InvalidInitiator();

        // SECURITY: Validate token and amount match context
        if (asset != _context.token) revert TokenMismatch();
        if (amount != _context.amount) revert AmountMismatch();

        // Transfer tokens to the actual recipient
        IERC20(asset).safeTransfer(_context.recipient, amount);

        // Call the recipient's callback
        bool success = IFlashLoanCallback(_context.recipient).onFlashLoanReceived(
            _context.initiator,
            asset,
            amount,
            premium,
            params
        );

        if (!success) revert FlashLoanFailed();

        // Verify we have enough to repay (recipient should have transferred back)
        uint256 repayAmount = amount + premium;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayment();

        // Approve Aave Pool to pull repayment
        IERC20(asset).forceApprove(address(AAVE_POOL), repayAmount);

        emit FlashLoanExecuted(asset, amount, premium, _context.recipient);

        return true;
    }

    /// @inheritdoc IFlashLoanAdapter
    function getFlashLoanFee(address /* token */, uint256 amount) external view override returns (uint256) {
        // Aave V3 has a 0.05% flash loan fee (5 bps)
        uint256 premium = AAVE_POOL.FLASHLOAN_PREMIUM_TOTAL();
        return (amount * premium) / BASIS_POINTS;
    }

    /// @inheritdoc IFlashLoanAdapter
    function isTokenSupported(address token) external view override returns (bool) {
        if (token == address(0)) return false;
        // Check if Aave Pool has any liquidity of the token
        // In practice, check aToken existence or balance
        return IERC20(token).balanceOf(address(AAVE_POOL)) > 0;
    }

    /// @inheritdoc IFlashLoanAdapter
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token == address(0)) return 0;
        // Maximum flash loan is the pool's token balance
        return IERC20(token).balanceOf(address(AAVE_POOL));
    }

    /// @inheritdoc IFlashLoanAdapter
    function getProvider() external view override returns (address) {
        return address(AAVE_POOL);
    }

    // ===== ADMIN FUNCTIONS =====

    /// @notice Pause the adapter, blocking new flash loan operations.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the adapter, re-enabling flash loan operations.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Recover tokens stuck in the adapter.
    /// @param token Token address to recover.
    /// @param amount Amount to transfer to the owner.
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount, owner());
    }
}
