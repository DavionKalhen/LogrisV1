// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ISwapper.sol";
import "../interfaces/curve/ICurveStableSwapFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CurvePoolSwapper
 * @notice Wraps a real Curve StableSwap NG pool to implement ISwapper interface
 * @dev Used to swap between alETH (debt) and WETH (underlying)
 */
contract CurvePoolSwapper is ISwapper {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE_DENOMINATOR = 1e10;

    // ============ State ============

    /// @notice The Curve pool address
    ICurveStableSwapNG public immutable pool;

    /// @notice Underlying token (WETH) - index 0 in pool
    address public immutable underlying;

    /// @notice Debt token (alETH) - index 1 in pool
    address public immutable debtToken;

    /// @notice Index of underlying token in pool
    int128 public immutable underlyingIndex;

    /// @notice Index of debt token in pool
    int128 public immutable debtIndex;

    // ============ Errors ============
    error PoolNotInitialized();
    error TokenMismatch();

    /**
     * @notice Constructor
     * @param _pool Address of the Curve StableSwap NG pool
     * @param _underlying Address of underlying token (WETH)
     * @param _debtToken Address of debt token (alETH)
     */
    constructor(
        address _pool,
        address _underlying,
        address _debtToken
    ) {
        require(_pool != address(0), "Invalid pool");
        pool = ICurveStableSwapNG(_pool);
        underlying = _underlying;
        debtToken = _debtToken;

        // Determine token indices in the pool
        address coin0 = pool.coins(0);
        address coin1 = pool.coins(1);

        if (coin0 == _underlying && coin1 == _debtToken) {
            underlyingIndex = 0;
            debtIndex = 1;
        } else if (coin0 == _debtToken && coin1 == _underlying) {
            underlyingIndex = 1;
            debtIndex = 0;
        } else {
            revert TokenMismatch();
        }
    }

    // ============ ISwapper Implementation ============

    /**
     * @notice Swap debt tokens (alETH) for underlying tokens (WETH)
     */
    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata /* swapData */
    ) external override returns (uint256 underlyingReceived) {
        if (debtAmount == 0) revert InvalidAmount();
        require(minUnderlyingOut > 0, "Min output required");
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer alETH from sender
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), debtAmount);

        // Approve pool to spend alETH
        IERC20(debtToken).approve(address(pool), debtAmount);

        // Execute swap: alETH -> WETH
        underlyingReceived = pool.exchange(
            debtIndex,
            underlyingIndex,
            debtAmount,
            minUnderlyingOut,
            recipient
        );

        emit SwapExecuted(debtToken, underlying, debtAmount, underlyingReceived, recipient);
    }

    /**
     * @notice Swap underlying tokens (WETH) for debt tokens (alETH)
     */
    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256 minDebtOut,
        address recipient,
        bytes calldata /* swapData */
    ) external override returns (uint256 debtReceived) {
        if (underlyingAmount == 0) revert InvalidAmount();
        require(minDebtOut > 0, "Min output required");
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer WETH from sender
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        // Approve pool to spend WETH
        IERC20(underlying).approve(address(pool), underlyingAmount);

        // Execute swap: WETH -> alETH
        debtReceived = pool.exchange(
            underlyingIndex,
            debtIndex,
            underlyingAmount,
            minDebtOut,
            recipient
        );

        emit SwapExecuted(underlying, debtToken, underlyingAmount, debtReceived, recipient);
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

        expectedUnderlying = pool.get_dy(debtIndex, underlyingIndex, debtAmount);
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

        expectedDebt = pool.get_dy(underlyingIndex, debtIndex, underlyingAmount);
        minimumOutput = 0;
    }

    /**
     * @notice Get current exchange rate from debt to underlying
     */
    function getDebtToUnderlyingRate() external view override returns (uint256 rate) {
        uint256 balance0 = pool.balances(0);
        if (balance0 == 0) return PRECISION;
        return pool.get_dy(debtIndex, underlyingIndex, PRECISION);
    }

    /**
     * @notice Get current exchange rate from underlying to debt
     */
    function getUnderlyingToDebtRate() external view override returns (uint256 rate) {
        uint256 balance0 = pool.balances(0);
        if (balance0 == 0) return PRECISION;
        return pool.get_dy(underlyingIndex, debtIndex, PRECISION);
    }

    /**
     * @notice Get swap fee in basis points
     */
    function getSwapFee() external view override returns (uint256) {
        // Curve fee is in 1e10 precision, convert to basis points
        return pool.fee() / 1e6;
    }

    /**
     * @notice Get slippage tolerance
     */
    function getSlippageTolerance() external pure override returns (uint256) {
        return 0;
    }

    /**
     * @notice Check if a token pair is supported
     */
    function isSupportedPair(address tokenA, address tokenB) external view override returns (bool) {
        return (tokenA == underlying && tokenB == debtToken) ||
               (tokenA == debtToken && tokenB == underlying);
    }

    // ============ View Functions ============

    /**
     * @notice Get pool reserves
     */
    function getReserves() external view returns (uint256 underlyingReserve, uint256 debtReserve) {
        underlyingReserve = pool.balances(uint256(int256(underlyingIndex)));
        debtReserve = pool.balances(uint256(int256(debtIndex)));
    }

    /**
     * @notice Get the pool address
     */
    function getPool() external view returns (address) {
        return address(pool);
    }
}
