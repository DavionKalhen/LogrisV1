// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../interfaces/flashloan/IFlashLoanAdapter.sol";
import "../../interfaces/flashloan/IFlashLoanCallback.sol";
import "../../interfaces/balancer/IVault.sol";
import "../../interfaces/balancer/IFlashLoanRecipient.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BalancerFlashLoanAdapter
 * @notice Flash loan adapter for Balancer V2 Vault
 * @dev Translates unified flash loan interface to Balancer-specific calls
 *
 * Security features:
 * - Reentrancy protection via nonReentrant modifier
 * - Caller validation on Balancer callback
 * - Context validation to prevent orphaned callbacks
 * - Pausable for emergency stops
 * - Owner-controlled for emergency withdrawals
 */
contract BalancerFlashLoanAdapter is IFlashLoanAdapter, IFlashLoanRecipient, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Balancer V2 Vault address (mainnet)
    address public constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    /// @notice The Balancer Vault contract
    IVault public immutable BALANCER_VAULT;

    /// @notice Indicates if a flash loan is in progress
    bool private _flashLoanInProgress;

    /// @notice Temporary storage for flash loan context
    struct FlashLoanContext {
        address initiator;
        address recipient;
        address token;
        uint256 amount;
    }
    FlashLoanContext private _context;

    /// @notice Emitted when emergency withdrawal occurs
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Error for context not initialized
    error ContextNotInitialized();

    /// @notice Error for invalid token
    error InvalidToken();

    error InvalidCaller();
    error SingleTokenOnly();
    error TokenMismatch();
    error AmountMismatch();

    /**
     * @notice Constructor
     * @param _balancerVault Optional custom vault address (uses mainnet default if zero)
     */
    constructor(address _balancerVault) Ownable(msg.sender) {
        BALANCER_VAULT = IVault(_balancerVault == address(0) ? BALANCER_V2_VAULT : _balancerVault);
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

        // Prepare Balancer flash loan parameters
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(token);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Execute flash loan through Balancer Vault
        // Balancer calls receiveFlashLoan on this contract
        BALANCER_VAULT.flashLoan(
            IFlashLoanRecipient(address(this)),
            tokens,
            amounts,
            data
        );

        // Clear state after completion
        _flashLoanInProgress = false;
        delete _context;
    }

    /**
     * @notice Balancer flash loan callback
     * @dev Called by Balancer Vault during flash loan execution
     *
     * SECURITY: Multiple validations ensure this can only be called
     * as part of a legitimate flash loan initiated by this contract
     */
    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external override {
        // SECURITY: Verify caller is Balancer Vault
        if (msg.sender != address(BALANCER_VAULT)) revert InvalidCaller();

        // SECURITY: Verify flash loan is in progress (prevents direct calls)
        if (!_flashLoanInProgress) revert ContextNotInitialized();

        // SECURITY: Single token validation
        if (tokens.length != 1) revert SingleTokenOnly();

        // SECURITY: Validate token matches context
        address token = address(tokens[0]);
        if (token != _context.token) revert TokenMismatch();

        uint256 amount = amounts[0];
        uint256 fee = feeAmounts[0];

        // SECURITY: Validate amount matches context
        if (amount != _context.amount) revert AmountMismatch();

        // Transfer tokens to the actual recipient
        IERC20(token).safeTransfer(_context.recipient, amount);

        // Call the recipient's callback
        // SECURITY: recipient is validated as non-zero in flashLoan()
        bool success = IFlashLoanCallback(_context.recipient).onFlashLoanReceived(
            _context.initiator,
            token,
            amount,
            fee,
            userData
        );

        if (!success) revert FlashLoanFailed();

        // Verify we have enough to repay (recipient should have transferred back)
        uint256 repayAmount = amount + fee;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayment();

        // Transfer tokens back to Balancer Vault (Balancer checks its balance after callback)
        IERC20(token).safeTransfer(address(BALANCER_VAULT), repayAmount);

        emit FlashLoanExecuted(token, amount, fee, _context.recipient);
    }

    /// @inheritdoc IFlashLoanAdapter
    function getFlashLoanFee(address /* token */, uint256 /* amount */) external pure override returns (uint256) {
        // Balancer V2 has 0% flash loan fees
        // But this could change via governance, so we leave room for future updates
        return 0;
    }

    /// @inheritdoc IFlashLoanAdapter
    function isTokenSupported(address token) external view override returns (bool) {
        if (token == address(0)) return false;
        // Balancer supports any token that has liquidity in the vault
        // Check if the vault has any balance of the token
        return IERC20(token).balanceOf(address(BALANCER_VAULT)) > 0;
    }

    /// @inheritdoc IFlashLoanAdapter
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token == address(0)) return 0;
        // Maximum flash loan is the vault's token balance
        return IERC20(token).balanceOf(address(BALANCER_VAULT));
    }

    /// @inheritdoc IFlashLoanAdapter
    function getProvider() external view override returns (address) {
        return address(BALANCER_VAULT);
    }

    // ===== ADMIN FUNCTIONS =====

    /**
     * @notice Pause flash loan operations
     * @dev Only callable by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause flash loan operations
     * @dev Only callable by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck tokens
     * @dev Only callable by owner. Should never be needed in normal operation.
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidToken();
        IERC20(token).safeTransfer(owner(), amount);
        emit EmergencyWithdrawal(token, amount, owner());
    }
}
