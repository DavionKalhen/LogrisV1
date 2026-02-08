// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../interfaces/ITokenConverter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @dev Local minimal interfaces to avoid import conflicts
interface IWETHConverter {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IStETHConverter {
    function submit(address _referral) external payable returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IWstETHConverter {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
}

interface ICurvePoolConverter {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @title WETHToWstETHConverter
/// @notice Converts between WETH and wstETH via Lido
/// @dev For toYield: WETH → ETH → stETH (Lido) → wstETH
/// @dev For toUnderlying: wstETH → stETH → ETH (Curve) → WETH
contract WETHToWstETHConverter is ITokenConverter, Ownable {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InvalidMinOutBps();
    error InsufficientYieldOutput();
    error NoETHToRescue();
    error ETHTransferFailed();

    /// @notice Emitted when WETH is converted to wstETH.
    /// @param wethAmount Amount of WETH consumed.
    /// @param wstEthAmount Amount of wstETH produced.
    /// @param recipient Address that received the wstETH.
    event ConvertedToYield(uint256 wethAmount, uint256 wstEthAmount, address indexed recipient);
    /// @notice Emitted when wstETH is converted to WETH.
    /// @param wstEthAmount Amount of wstETH consumed.
    /// @param wethAmount Amount of WETH produced.
    /// @param recipient Address that received the WETH.
    event ConvertedToUnderlying(uint256 wstEthAmount, uint256 wethAmount, address indexed recipient);
    /// @notice Emitted when stuck ETH is rescued by the owner.
    /// @param amount Amount of ETH rescued.
    /// @param recipient Address that received the ETH.
    event ETHRescued(uint256 amount, address indexed recipient);

    uint256 private constant BASIS_POINTS = 10_000;

    address public immutable WETH;
    address public immutable STETH;
    address public immutable WSTETH;

    // Curve stETH/ETH pool for unwrapping
    address public immutable CURVE_STETH_POOL;
    int128 public immutable CURVE_ETH_INDEX;
    int128 public immutable CURVE_STETH_INDEX;

    // Minimum output in basis points (e.g., 9950 = 0.5% slippage)
    uint256 public immutable MIN_OUT_BPS;

    /// @param _weth WETH contract address.
    /// @param _steth stETH (Lido) contract address.
    /// @param _wsteth wstETH (wrapped stETH) contract address.
    /// @param _curvePool Curve stETH/ETH pool address for unwrapping.
    /// @param _ethIndex Index of ETH in the Curve pool.
    /// @param _stethIndex Index of stETH in the Curve pool.
    /// @param _minOutBps Minimum output in basis points (1-10000).
    /// @param _owner Owner address authorized to call rescueETH.
    constructor(
        address _weth,
        address _steth,
        address _wsteth,
        address _curvePool,
        int128 _ethIndex,
        int128 _stethIndex,
        uint256 _minOutBps,
        address _owner
    ) Ownable(_owner) {
        if (_weth == address(0)) revert ZeroAddress();
        if (_steth == address(0)) revert ZeroAddress();
        if (_wsteth == address(0)) revert ZeroAddress();
        if (_curvePool == address(0)) revert ZeroAddress();
        if (_minOutBps == 0 || _minOutBps > BASIS_POINTS) revert InvalidMinOutBps();

        WETH = _weth;
        STETH = _steth;
        WSTETH = _wsteth;
        CURVE_STETH_POOL = _curvePool;
        CURVE_ETH_INDEX = _ethIndex;
        CURVE_STETH_INDEX = _stethIndex;
        MIN_OUT_BPS = _minOutBps;
    }

    /// @inheritdoc ITokenConverter
    function yieldToken() external view override returns (address) {
        return WSTETH;
    }

    /// @inheritdoc ITokenConverter
    function underlyingToken() external view override returns (address) {
        return WETH;
    }

    /// @notice Convert WETH to wstETH via Lido staking
    /// @dev WETH → ETH → stETH (Lido submit) → wstETH
    function toYield(
        uint256 amount,
        address recipient,
        uint256 minYieldOut
    ) external override returns (uint256 wstEthAmount) {
        // 1. Pull WETH from caller
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);

        // 2. WETH → ETH
        IWETHConverter(WETH).withdraw(amount);

        // 3. ETH → stETH (stake with Lido)
        uint256 stEthReceived = IStETHConverter(STETH).submit{value: amount}(address(0));

        // 4. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        wstEthAmount = IWstETHConverter(WSTETH).wrap(stEthReceived);
        if (wstEthAmount < minYieldOut) revert InsufficientYieldOutput();

        // 5. Transfer to recipient
        IERC20(WSTETH).safeTransfer(recipient, wstEthAmount);

        emit ConvertedToYield(amount, wstEthAmount, recipient);
    }

    /// @notice Convert wstETH to WETH via Curve
    /// @dev wstETH → stETH → ETH (Curve swap) → WETH
    function toUnderlying(
        uint256 amount,
        address recipient,
        uint256 minUnderlyingOut
    ) external override returns (uint256 wethAmount) {
        // 1. Pull wstETH from caller
        IERC20(WSTETH).safeTransferFrom(msg.sender, address(this), amount);

        // 2. wstETH → stETH
        uint256 stEthReceived = IWstETHConverter(WSTETH).unwrap(amount);

        // 3. stETH → ETH via Curve
        IERC20(STETH).forceApprove(CURVE_STETH_POOL, stEthReceived);

        uint256 ethReceived = ICurvePoolConverter(CURVE_STETH_POOL).exchange(
            CURVE_STETH_INDEX,
            CURVE_ETH_INDEX,
            stEthReceived,
            minUnderlyingOut
        );

        // 4. ETH → WETH
        IWETHConverter(WETH).deposit{value: ethReceived}();
        wethAmount = ethReceived;

        // 5. Transfer to recipient
        IERC20(WETH).safeTransfer(recipient, wethAmount);

        emit ConvertedToUnderlying(amount, wethAmount, recipient);
    }

    /// @notice Preview WETH → wstETH conversion
    function previewToYield(uint256 amount) external view override returns (uint256) {
        // stETH received ≈ ETH amount (1:1 on deposit)
        // wstETH = stETH / stEthPerToken
        return IWstETHConverter(WSTETH).getWstETHByStETH(amount);
    }

    /// @notice Preview wstETH → WETH conversion
    function previewToUnderlying(uint256 amount) external view override returns (uint256) {
        // wstETH → stETH
        uint256 stEthAmount = IWstETHConverter(WSTETH).getStETHByWstETH(amount);
        // stETH → ETH via Curve (includes slippage)
        return ICurvePoolConverter(CURVE_STETH_POOL).get_dy(CURVE_STETH_INDEX, CURVE_ETH_INDEX, stEthAmount);
    }

    /// @notice Rescue any ETH dust stuck from failed conversion operations
    /// @param recipient Address to receive the rescued ETH.
    function rescueETH(address payable recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToRescue();
        (bool success,) = recipient.call{value: balance}("");
        if (!success) revert ETHTransferFailed();
        emit ETHRescued(balance, recipient);
    }

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
