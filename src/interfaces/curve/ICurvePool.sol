// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ICurvePool
 * @notice Interface for Curve StableSwap pools (alETH/ETH, alUSD/3CRV, etc.)
 * @dev Different Curve pools may have slightly different interfaces
 */
interface ICurvePool {
    /**
     * @notice Get the amount of coin j one would receive for swapping dx of coin i
     * @param i Index of input coin
     * @param j Index of output coin
     * @param dx Amount of input coin
     * @return Expected output amount
     */
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /**
     * @notice Get the amount of coin j one would receive for swapping dx of coin i
     * @dev Some pools use uint256 indices instead of int128
     * @param i Index of input coin
     * @param j Index of output coin
     * @param dx Amount of input coin
     * @return Expected output amount
     */
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);

    /**
     * @notice Exchange (swap) coin i for coin j
     * @param i Index of input coin
     * @param j Index of output coin
     * @param dx Amount of input coin
     * @param min_dy Minimum amount of output coin to receive
     * @return Actual output amount received
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);

    /**
     * @notice Exchange with uint256 indices (for newer pools)
     */
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    /**
     * @notice Exchange with recipient parameter
     */
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) external returns (uint256);

    /**
     * @notice Get balance of coin at index
     * @param i Index of the coin
     * @return Balance of the coin in the pool
     */
    function balances(uint256 i) external view returns (uint256);

    /**
     * @notice Get address of coin at index
     * @param i Index of the coin
     * @return Address of the coin
     */
    function coins(uint256 i) external view returns (address);

    /**
     * @notice Get number of coins in the pool
     * @return Number of coins
     */
    function N_COINS() external view returns (uint256);

    /**
     * @notice Get the amplification coefficient
     * @return A parameter
     */
    function A() external view returns (uint256);

    /**
     * @notice Get the pool's fee
     * @return Fee in 1e10 precision (e.g., 4000000 = 0.04%)
     */
    function fee() external view returns (uint256);

    /**
     * @notice Get admin fee percentage
     * @return Admin fee in 1e10 precision
     */
    function admin_fee() external view returns (uint256);

    /**
     * @notice Get virtual price of LP token
     * @return Virtual price scaled by 1e18
     */
    function get_virtual_price() external view returns (uint256);
}

/**
 * @title ICurvePoolETH
 * @notice Interface for Curve pools that deal with native ETH
 * @dev The alETH/ETH pool uses ETH (represented as 0xEeee...)
 */
interface ICurvePoolETH {
    /**
     * @notice Exchange with ETH support
     * @dev Use msg.value for ETH input when i=0 (assuming ETH is index 0)
     */
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
}

/**
 * @title ICurveMetapool
 * @notice Interface for Curve metapools (e.g., alUSD/3CRV)
 * @dev Metapools allow trading against a base pool
 */
interface ICurveMetapool is ICurvePool {
    /**
     * @notice Exchange underlying tokens (not LP tokens)
     * @param i Index of input underlying coin
     * @param j Index of output underlying coin
     * @param dx Amount of input coin
     * @param min_dy Minimum amount of output coin
     * @return Actual output amount
     */
    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    /**
     * @notice Get expected output for underlying exchange
     */
    function get_dy_underlying(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);
}
