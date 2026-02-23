// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../interfaces/ISwapper.sol";
import "../interfaces/curve/ICurvePool.sol";
import {IWETH} from "alchemix-v3/src/interfaces/IWETH.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title CurveSwapper
 * @notice Production swapper that integrates with Curve pools for alETH/ETH swaps
 * @dev Designed for the alETH+ETH factory pool on Ethereum mainnet
 */
contract CurveSwapper is ISwapper, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;
    /// @dev Divisor to convert Curve's 1e10-precision fee to basis points (1e4).
    uint256 private constant CURVE_FEE_TO_BPS = 1e6;

    // Curve pool configuration
    address public immutable CURVE_POOL;
    address public immutable DEBT_TOKEN; // alETH
    address public immutable UNDERLYING_TOKEN; // WETH
    address public immutable WETH;
    bool public immutable USES_ETH;

    // Pool indices (for alETH/ETH pool: 0=ETH, 1=alETH)
    int128 public immutable ETH_INDEX;
    int128 public immutable AL_ETH_INDEX;

    // Events
    /// @notice Emitted when the Curve pool is configured at deployment.
    /// @param pool The Curve pool address.
    /// @param debtToken The debt token address (alETH).
    /// @param underlyingToken The underlying token address (WETH).
    event PoolConfigured(address indexed pool, address indexed debtToken, address indexed underlyingToken);
    /// @notice Emitted when the owner executes an emergency withdrawal.
    /// @param token The token address withdrawn (address(0) for native ETH).
    /// @param amount The amount withdrawn.
    /// @param recipient The address that received the tokens.
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);

    // Errors
    error ZeroAddress();
    error UnderlyingMustBeWETH();
    error MinOutputRequired();
    error ETHTransferFailed();

    /**
     * @notice Constructor
     * @param _curvePool Address of the Curve pool (alETH/ETH)
     * @param _debtToken Address of debt token (alETH)
     * @param _underlyingToken Address of underlying token (WETH)
     * @param _ethIndex Index of ETH in the pool
     * @param _alEthIndex Index of alETH in the pool
     * @param _weth Address of WETH (used only when pool uses ETH)
     * @param _usesEth True if pool trades native ETH instead of WETH
     * @param _owner Owner address
     */
    constructor(
        address _curvePool,
        address _debtToken,
        address _underlyingToken,
        int128 _ethIndex,
        int128 _alEthIndex,
        address _weth,
        bool _usesEth,
        address _owner
    ) Ownable(_owner) {
        if (_curvePool == address(0)) revert ZeroAddress();
        if (_debtToken == address(0)) revert ZeroAddress();
        if (_underlyingToken == address(0)) revert ZeroAddress();
        if (_weth == address(0)) revert ZeroAddress();
        if (_usesEth) {
            if (_underlyingToken != _weth) revert UnderlyingMustBeWETH();
        }

        CURVE_POOL = _curvePool;
        DEBT_TOKEN = _debtToken;
        UNDERLYING_TOKEN = _underlyingToken;
        ETH_INDEX = _ethIndex;
        AL_ETH_INDEX = _alEthIndex;
        WETH = _weth;
        USES_ETH = _usesEth;

        emit PoolConfigured(_curvePool, _debtToken, _underlyingToken);
    }

    /**
     * @notice Swap debt tokens (alETH) for underlying tokens (WETH)
     * @dev Swaps alETH -> ETH via Curve, then wraps ETH -> WETH
     */
    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata /* swapData */
    ) external override nonReentrant whenNotPaused returns (uint256 underlyingReceived) {
        if (debtAmount == 0) revert InvalidAmount();
        if (minUnderlyingOut == 0) revert MinOutputRequired();
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer alETH from sender
        IERC20(DEBT_TOKEN).safeTransferFrom(msg.sender, address(this), debtAmount);

        // Approve pool to spend alETH
        IERC20(DEBT_TOKEN).forceApprove(CURVE_POOL, debtAmount);

        if (USES_ETH) {
            // Execute swap: alETH -> ETH
            uint256 ethReceived = ICurvePoolETH(CURVE_POOL).exchange(
                AL_ETH_INDEX,
                ETH_INDEX,
                debtAmount,
                minUnderlyingOut
            );

            // Wrap ETH -> WETH
            IWETH(WETH).deposit{value: ethReceived}();

            // Transfer WETH to recipient
            IERC20(UNDERLYING_TOKEN).safeTransfer(recipient, ethReceived);

            underlyingReceived = ethReceived;
        } else {
            underlyingReceived = ICurvePool(CURVE_POOL).exchange(
                AL_ETH_INDEX,
                ETH_INDEX,
                debtAmount,
                minUnderlyingOut
            );
            IERC20(UNDERLYING_TOKEN).safeTransfer(recipient, underlyingReceived);
        }

        emit SwapExecuted(DEBT_TOKEN, UNDERLYING_TOKEN, debtAmount, underlyingReceived, recipient);

        return underlyingReceived;
    }

    /**
     * @notice Swap underlying tokens (WETH) for debt tokens (alETH)
     * @dev Unwraps WETH -> ETH, then swaps ETH -> alETH via Curve
     */
    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256 minDebtOut,
        address recipient,
        bytes calldata /* swapData */
    ) external override nonReentrant whenNotPaused returns (uint256 debtReceived) {
        if (underlyingAmount == 0) revert InvalidAmount();
        if (minDebtOut == 0) revert MinOutputRequired();
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer WETH from sender
        IERC20(UNDERLYING_TOKEN).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        if (USES_ETH) {
            // Unwrap WETH -> ETH
            IWETH(WETH).withdraw(underlyingAmount);

            // Execute swap: ETH -> alETH
            debtReceived = ICurvePoolETH(CURVE_POOL).exchange{value: underlyingAmount}(
                ETH_INDEX,
                AL_ETH_INDEX,
                underlyingAmount,
                minDebtOut
            );
        } else {
            IERC20(UNDERLYING_TOKEN).forceApprove(CURVE_POOL, underlyingAmount);
            debtReceived = ICurvePool(CURVE_POOL).exchange(
                ETH_INDEX,
                AL_ETH_INDEX,
                underlyingAmount,
                minDebtOut
            );
        }

        // Transfer alETH to recipient
        IERC20(DEBT_TOKEN).safeTransfer(recipient, debtReceived);

        emit SwapExecuted(UNDERLYING_TOKEN, DEBT_TOKEN, underlyingAmount, debtReceived, recipient);

        return debtReceived;
    }

    /**
     * @notice Preview swap output for debt to underlying
     */
    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external
        view
        override
        returns (uint256 expectedUnderlying, uint256 minimumOutput)
    {
        if (debtAmount == 0) return (0, 0);

        expectedUnderlying = ICurvePool(CURVE_POOL).get_dy(AL_ETH_INDEX, ETH_INDEX, debtAmount);
        minimumOutput = 0;
    }

    /**
     * @notice Preview swap output for underlying to debt
     */
    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external
        view
        override
        returns (uint256 expectedDebt, uint256 minimumOutput)
    {
        if (underlyingAmount == 0) return (0, 0);

        expectedDebt = ICurvePool(CURVE_POOL).get_dy(ETH_INDEX, AL_ETH_INDEX, underlyingAmount);
        minimumOutput = 0;
    }

    /**
     * @notice Get current exchange rate from debt to underlying
     */
    function getDebtToUnderlyingRate() external view override returns (uint256 rate) {
        // Get rate for 1 alETH -> ETH
        uint256 output = ICurvePool(CURVE_POOL).get_dy(AL_ETH_INDEX, ETH_INDEX, PRECISION);
        return output;
    }

    /**
     * @notice Get current exchange rate from underlying to debt
     */
    function getUnderlyingToDebtRate() external view override returns (uint256 rate) {
        // Get rate for 1 ETH -> alETH
        uint256 output = ICurvePool(CURVE_POOL).get_dy(ETH_INDEX, AL_ETH_INDEX, PRECISION);
        return output;
    }

    /**
     * @notice Get swap fee from the pool
     * @dev Curve fees are in 1e10 precision (e.g., 4000000 = 0.04%)
     */
    function getSwapFee() external view override returns (uint256 fee) {
        uint256 poolFee = ICurvePool(CURVE_POOL).fee();
        // Convert from 1e10 to basis points (1e4)
        return poolFee / CURVE_FEE_TO_BPS;
    }

    /**
     * @notice Get slippage tolerance in basis points
     */
    function getSlippageTolerance() external pure override returns (uint256 tolerance) {
        return 0;
    }

    /**
     * @notice Check if a token pair is supported
     */
    function isSupportedPair(address tokenA, address tokenB) external view override returns (bool supported) {
        return (tokenA == DEBT_TOKEN && tokenB == UNDERLYING_TOKEN) ||
            (tokenA == UNDERLYING_TOKEN && tokenB == DEBT_TOKEN);
    }

    // ===== ADMIN FUNCTIONS =====

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Emergency withdraw stuck tokens (only owner)
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success,) = owner().call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdrawal(token, amount, owner());
    }

    /**
     * @notice Receive ETH (needed for Curve swaps)
     */
    receive() external payable {}
}
