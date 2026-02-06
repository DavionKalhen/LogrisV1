// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Use the alchemix-v3 interfaces
import "../../alchemix-v3/src/interfaces/ITokenAdapter.sol";
import {IWETH} from "../../alchemix-v3/src/interfaces/IWETH.sol";
import "../interfaces/ISwapper.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

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
contract WstETHAdapter is ITokenAdapter {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    /// @notice wstETH token address (mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice stETH token address (mainnet)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice WETH address (mainnet)
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Swapper used for stETH -> WETH conversion
    ISwapper public immutable swapper;
    uint256 public immutable minOutBps;

    constructor(address _swapper, uint256 _minOutBps) {
        require(_swapper != address(0), "Invalid swapper");
        require(_minOutBps > 0 && _minOutBps <= BASIS_POINTS, "Invalid minOutBps");
        require(ISwapper(_swapper).isSupportedPair(STETH, WETH), "Unsupported pair");
        swapper = ISwapper(_swapper);
        minOutBps = _minOutBps;
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
        IERC20(STETH).forceApprove(address(swapper), stETHReceived);

        (uint256 expectedOut,) = swapper.previewSwapDebtToUnderlying(stETHReceived);
        uint256 minOut = (expectedOut * minOutBps) / BASIS_POINTS;
        require(minOut > 0, "Min output required");

        // 3. Swap stETH -> WETH using configured swapper
        wethAmount = swapper.swapDebtToUnderlying(stETHReceived, minOut, recipient, "");
    }

    /// @notice Rescue any ETH dust stuck from failed wrapping operations
    function rescueETH(address payable recipient) external {
        require(recipient != address(0), "Invalid recipient");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to rescue");
        (bool success,) = recipient.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    // Allow contract to receive ETH from WETH.withdraw()
    receive() external payable {}
}
