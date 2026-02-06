// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ISwapper.sol";
import "../interfaces/curve/ICurvePool.sol";
import {IWETH} from "alchemix-v3/src/interfaces/IWETH.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title CurveSwapper
 * @notice Production swapper that integrates with Curve pools for alETH/ETH swaps
 * @dev Designed for the alETH+ETH factory pool on Ethereum mainnet
 */
contract CurveSwapper is ISwapper, Ownable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;

    // Curve pool configuration
    address public immutable curvePool;
    address public immutable debtToken; // alETH
    address public immutable underlyingToken; // WETH
    address public immutable weth;
    bool public immutable usesEth;

    // Pool indices (for alETH/ETH pool: 0=ETH, 1=alETH)
    int128 public immutable ethIndex;
    int128 public immutable alEthIndex;

    // Events
    event PoolConfigured(address pool, address debtToken, address underlyingToken);

    // Errors
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
        require(_curvePool != address(0), "Invalid pool");
        require(_debtToken != address(0), "Invalid debt token");
        require(_underlyingToken != address(0), "Invalid underlying token");
        require(_weth != address(0), "Invalid WETH");
        if (_usesEth) {
            require(_underlyingToken == _weth, "Underlying must be WETH");
        }

        curvePool = _curvePool;
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
        ethIndex = _ethIndex;
        alEthIndex = _alEthIndex;
        weth = _weth;
        usesEth = _usesEth;

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
    ) external override returns (uint256 underlyingReceived) {
        if (debtAmount == 0) revert InvalidAmount();
        require(minUnderlyingOut > 0, "Min output required");
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer alETH from sender
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), debtAmount);

        // Approve pool to spend alETH
        IERC20(debtToken).forceApprove(curvePool, debtAmount);

        if (usesEth) {
            // Execute swap: alETH -> ETH
            uint256 ethReceived = ICurvePoolETH(curvePool).exchange(
                alEthIndex,
                ethIndex,
                debtAmount,
                minUnderlyingOut
            );

            // Wrap ETH -> WETH
            IWETH(weth).deposit{value: ethReceived}();

            // Transfer WETH to recipient
            IERC20(underlyingToken).safeTransfer(recipient, ethReceived);

            underlyingReceived = ethReceived;
        } else {
            underlyingReceived = ICurvePool(curvePool).exchange(
                alEthIndex,
                ethIndex,
                debtAmount,
                minUnderlyingOut
            );
            IERC20(underlyingToken).safeTransfer(recipient, underlyingReceived);
        }

        emit SwapExecuted(debtToken, underlyingToken, debtAmount, underlyingReceived, recipient);

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
    ) external override returns (uint256 debtReceived) {
        if (underlyingAmount == 0) revert InvalidAmount();
        require(minDebtOut > 0, "Min output required");
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer WETH from sender
        IERC20(underlyingToken).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        if (usesEth) {
            // Unwrap WETH -> ETH
            IWETH(weth).withdraw(underlyingAmount);

            // Execute swap: ETH -> alETH
            debtReceived = ICurvePoolETH(curvePool).exchange{value: underlyingAmount}(
                ethIndex,
                alEthIndex,
                underlyingAmount,
                minDebtOut
            );
        } else {
            IERC20(underlyingToken).forceApprove(curvePool, underlyingAmount);
            debtReceived = ICurvePool(curvePool).exchange(
                ethIndex,
                alEthIndex,
                underlyingAmount,
                minDebtOut
            );
        }

        // Transfer alETH to recipient
        IERC20(debtToken).safeTransfer(recipient, debtReceived);

        emit SwapExecuted(underlyingToken, debtToken, underlyingAmount, debtReceived, recipient);

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

        expectedUnderlying = ICurvePool(curvePool).get_dy(alEthIndex, ethIndex, debtAmount);
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

        expectedDebt = ICurvePool(curvePool).get_dy(ethIndex, alEthIndex, underlyingAmount);
        minimumOutput = 0;
    }

    /**
     * @notice Get current exchange rate from debt to underlying
     */
    function getDebtToUnderlyingRate() external view override returns (uint256 rate) {
        // Get rate for 1 alETH -> ETH
        uint256 output = ICurvePool(curvePool).get_dy(alEthIndex, ethIndex, PRECISION);
        return output;
    }

    /**
     * @notice Get current exchange rate from underlying to debt
     */
    function getUnderlyingToDebtRate() external view override returns (uint256 rate) {
        // Get rate for 1 ETH -> alETH
        uint256 output = ICurvePool(curvePool).get_dy(ethIndex, alEthIndex, PRECISION);
        return output;
    }

    /**
     * @notice Get swap fee from the pool
     * @dev Curve fees are in 1e10 precision (e.g., 4000000 = 0.04%)
     */
    function getSwapFee() external view override returns (uint256 fee) {
        uint256 poolFee = ICurvePool(curvePool).fee();
        // Convert from 1e10 to basis points (1e4)
        return poolFee / 1e6;
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
        return (tokenA == debtToken && tokenB == underlyingToken) ||
            (tokenA == underlyingToken && tokenB == debtToken);
    }

    // ===== ADMIN FUNCTIONS =====

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
    }

    /**
     * @notice Receive ETH (needed for Curve swaps)
     */
    receive() external payable {}
}
