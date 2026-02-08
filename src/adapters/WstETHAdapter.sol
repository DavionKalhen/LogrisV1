// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Use the alchemix-v3 interfaces
import "../../alchemix-v3/src/interfaces/ITokenAdapter.sol";
import {IWETH} from "../../alchemix-v3/src/interfaces/IWETH.sol";
import "../interfaces/ISwapper.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title IWstETH
 * @notice Interface for Lido's wrapped stETH
 */
interface IWstETH {
    function stEthPerToken() external view returns (uint256);
    function tokensPerStEth() external view returns (uint256);
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title IStETH
 * @notice Interface for Lido's stETH (rebasing)
 */
interface IStETH {
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function submit(address _referral) external payable returns (uint256);
}

/**
 * @title WstETHAdapter
 * @notice Token adapter for wstETH yield token using real mainnet wstETH
 * @dev Implements ITokenAdapter for integration with AlchemistV3
 *
 * wstETH is a non-rebasing wrapper around stETH. The exchange rate
 * increases over time as stETH accrues staking rewards.
 *
 * Price represents: ETH value per wstETH token
 */
contract WstETHAdapter is ITokenAdapter, Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidMinOutBps();
    error UnsupportedPair();
    error MinOutputRequired();
    error NoETHToRescue();
    error ETHTransferFailed();

    /// @notice Emitted when WETH is wrapped to wstETH.
    /// @param wethAmount Amount of WETH consumed.
    /// @param wstEthAmount Amount of wstETH produced.
    /// @param recipient Address that received the wstETH.
    event Wrapped(uint256 wethAmount, uint256 wstEthAmount, address indexed recipient);
    /// @notice Emitted when wstETH is unwrapped to WETH.
    /// @param wstEthAmount Amount of wstETH consumed.
    /// @param wethAmount Amount of WETH produced.
    /// @param recipient Address that received the WETH.
    event Unwrapped(uint256 wstEthAmount, uint256 wethAmount, address indexed recipient);
    /// @notice Emitted when stuck ETH is rescued by the owner.
    /// @param amount Amount of ETH rescued.
    /// @param recipient Address that received the ETH.
    event ETHRescued(uint256 amount, address indexed recipient);

    uint256 private constant BASIS_POINTS = 10_000;

    /// @notice wstETH token address (mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice stETH token address (mainnet)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice WETH address (mainnet)
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Swapper used for stETH -> WETH conversion
    ISwapper public immutable SWAPPER;
    /// @notice Minimum output in basis points for unwrap operations (e.g. 9950 = 0.5% max slippage)
    uint256 public immutable MIN_OUT_BPS;

    /// @param _swapper Swapper contract for stETH -> WETH conversion.
    /// @param _minOutBps Minimum output in basis points (1-10000).
    /// @param _owner Owner address authorized to call rescueETH.
    constructor(address _swapper, uint256 _minOutBps, address _owner) Ownable(_owner) {
        if (_swapper == address(0)) revert ZeroAddress();
        if (_minOutBps == 0 || _minOutBps > BASIS_POINTS) revert InvalidMinOutBps();
        if (!ISwapper(_swapper).isSupportedPair(STETH, WETH)) revert UnsupportedPair();
        SWAPPER = ISwapper(_swapper);
        MIN_OUT_BPS = _minOutBps;
    }

    /**
     * @notice Returns the yield token (wstETH)
     */
    function token() external pure override returns (address) {
        return WSTETH;
    }

    /**
     * @notice Returns the underlying token (WETH/ETH)
     * @dev wstETH's underlying value is denominated in ETH
     */
    function underlyingToken() external pure override returns (address) {
        return WETH;
    }

    /**
     * @notice Returns the adapter version
     */
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Returns the price of wstETH in terms of underlying (ETH)
     * @dev Uses stEthPerToken() which returns how much stETH equals 1 wstETH
     *      Since stETH is 1:1 with ETH (rebasing), this gives ETH value per wstETH
     * @return The exchange rate with 18 decimal precision
     */
    function price() external view override returns (uint256) {
        // stEthPerToken returns the amount of stETH per 1 wstETH
        // Since stETH rebases to track ETH value, this is effectively ETH per wstETH
        return IWstETH(WSTETH).stEthPerToken();
    }

    /**
     * @notice Wrap WETH into wstETH
     * @param amount Amount of WETH to wrap
     * @param recipient Address to receive the wstETH
     * @return wstETHAmount Amount of wstETH received
     */
    function wrap(uint256 amount, address recipient) external returns (uint256 wstETHAmount) {
        // 1. Pull WETH from caller
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Unwrap WETH to ETH
        IWETH(WETH).withdraw(amount);

        // 3. Submit ETH to Lido to get stETH
        uint256 stETHReceived = IStETH(STETH).submit{value: amount}(address(0));

        // 4. Approve wstETH to take stETH
        IERC20(STETH).forceApprove(WSTETH, stETHReceived);

        // 5. Wrap stETH to wstETH
        wstETHAmount = IWstETH(WSTETH).wrap(stETHReceived);

        // 6. Transfer wstETH to recipient
        IERC20(WSTETH).safeTransfer(recipient, wstETHAmount);

        emit Wrapped(amount, wstETHAmount, recipient);
    }

    /**
     * @notice Unwrap wstETH into WETH
     * @param amount Amount of wstETH to unwrap
     * @param recipient Address to receive the WETH
     * @return wethAmount Amount of WETH received
     */
    function unwrap(uint256 amount, address recipient) external returns (uint256 wethAmount) {
        // 1. Pull wstETH from caller
        IERC20(WSTETH).safeTransferFrom(msg.sender, address(this), amount);

        // 2. Unwrap wstETH to stETH
        uint256 stETHReceived = IWstETH(WSTETH).unwrap(amount);
        IERC20(STETH).forceApprove(address(SWAPPER), stETHReceived);

        (uint256 expectedOut,) = SWAPPER.previewSwapDebtToUnderlying(stETHReceived);
        uint256 minOut = (expectedOut * MIN_OUT_BPS) / BASIS_POINTS;
        if (minOut == 0) revert MinOutputRequired();

        // 3. Swap stETH -> WETH using configured swapper
        wethAmount = SWAPPER.swapDebtToUnderlying(stETHReceived, minOut, recipient, "");

        emit Unwrapped(amount, wethAmount, recipient);
    }

    /// @notice Rescue any ETH dust stuck from failed wrapping operations
    /// @param recipient Address to receive the rescued ETH.
    function rescueETH(address payable recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToRescue();
        (bool success,) = recipient.call{value: balance}("");
        if (!success) revert ETHTransferFailed();
        emit ETHRescued(balance, recipient);
    }

    // Allow contract to receive ETH from WETH.withdraw()
    receive() external payable {}
}
