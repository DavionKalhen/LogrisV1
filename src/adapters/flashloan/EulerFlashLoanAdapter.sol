// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../../interfaces/flashloan/IFlashLoanAdapter.sol";
import "../../interfaces/flashloan/IFlashLoanCallback.sol";
import "../../interfaces/euler/DToken.sol";
import "../../interfaces/euler/IFlashLoan.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title EulerFlashLoanAdapter
 * @notice Flash loan adapter for Euler Finance DTokens
 * @dev Translates unified flash loan interface to Euler-specific calls
 *
 * Security features:
 * - Access control via Ownable for setDToken
 * - Reentrancy protection via OpenZeppelin ReentrancyGuard
 * - Pausable for emergency stops
 */
contract EulerFlashLoanAdapter is IFlashLoanAdapter, IFlashLoan, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Mapping of underlying tokens to their Euler DToken addresses
    mapping(address => address) public dTokens;

    /// @notice Temporary storage for flash loan context
    struct FlashLoanContext {
        address initiator;
        address recipient;
        address token;
        uint256 amount;
        bytes userData;
    }
    FlashLoanContext private _context;

    /// @notice Emitted when emergency withdrawal occurs
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);

    /// @notice Emitted when a DToken mapping is updated
    event DTokenSet(address indexed underlying, address indexed dToken);

    /// @notice Error for invalid token address
    error InvalidToken();

    /**
     * @notice Constructor
     * @param _underlyingTokens Array of underlying token addresses
     * @param _dTokenAddresses Array of corresponding DToken addresses
     */
    constructor(address[] memory _underlyingTokens, address[] memory _dTokenAddresses) Ownable(msg.sender) {
        require(_underlyingTokens.length == _dTokenAddresses.length, "Length mismatch");
        for (uint256 i = 0; i < _underlyingTokens.length; i++) {
            dTokens[_underlyingTokens[i]] = _dTokenAddresses[i];
        }
    }

    /**
     * @notice Add or update a DToken mapping
     * @dev Only callable by owner - critical for security as this controls flash loan routing
     * @param underlying The underlying token address
     * @param dToken The DToken address
     */
    function setDToken(address underlying, address dToken) external onlyOwner {
        dTokens[underlying] = dToken;
        emit DTokenSet(underlying, dToken);
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

        address dToken = dTokens[token];
        if (dToken == address(0)) revert UnsupportedToken();

        // Store context for callback
        _context = FlashLoanContext({
            initiator: msg.sender,
            recipient: recipient,
            token: token,
            amount: amount,
            userData: data
        });

        // Execute flash loan through Euler DToken
        // Euler calls onFlashLoan on this contract
        DToken(dToken).flashLoan(amount, data);

        // Clear context after completion
        delete _context;
    }

    /**
     * @notice Euler flash loan callback
     * @dev Called by Euler DToken during flash loan execution
     */
    function onFlashLoan(bytes memory data) external override {
        // Verify caller is the expected DToken
        address expectedDToken = dTokens[_context.token];
        require(msg.sender == expectedDToken, "Invalid caller");

        address token = _context.token;
        uint256 amount = _context.amount;
        uint256 fee = 0; // Euler has 0% flash loan fees

        // Transfer tokens to the actual recipient
        IERC20(token).safeTransfer(_context.recipient, amount);

        // Call the recipient's callback
        bool success = IFlashLoanCallback(_context.recipient).onFlashLoanReceived(
            _context.initiator,
            token,
            amount,
            fee,
            data
        );

        if (!success) revert FlashLoanFailed();

        // Verify we have enough to repay (recipient should have transferred back)
        uint256 repayAmount = amount + fee;
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < repayAmount) revert InsufficientRepayment();

        // Approve DToken to pull repayment
        IERC20(token).forceApprove(msg.sender, repayAmount);

        emit FlashLoanExecuted(token, amount, fee, _context.recipient);
    }

    /// @inheritdoc IFlashLoanAdapter
    function getFlashLoanFee(address, uint256) external pure override returns (uint256) {
        // Euler has 0% flash loan fees
        return 0;
    }

    /// @inheritdoc IFlashLoanAdapter
    function isTokenSupported(address token) external view override returns (bool) {
        return dTokens[token] != address(0);
    }

    /// @inheritdoc IFlashLoanAdapter
    function maxFlashLoan(address token) external view override returns (uint256) {
        address dToken = dTokens[token];
        if (dToken == address(0)) return 0;
        // Max flash loan is the DToken's underlying balance
        return IERC20(token).balanceOf(dToken);
    }

    /// @inheritdoc IFlashLoanAdapter
    function getProvider() external view override returns (address) {
        // Return the first DToken as provider (or address(0) if none)
        // In practice, each token has its own DToken provider
        return address(this);
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
