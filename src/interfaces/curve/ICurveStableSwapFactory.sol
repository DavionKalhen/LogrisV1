// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ICurveStableSwapFactory
 * @notice Interface for Curve StableSwap Factory NG
 * @dev Factory address on mainnet: 0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf
 */
interface ICurveStableSwapFactory {
    /**
     * @notice Deploy a new plain pool (no meta, no rebasing)
     * @param _name Pool name (e.g., "Curve.fi alETH/WETH")
     * @param _symbol LP token symbol (e.g., "alETH-WETH")
     * @param _coins Array of coin addresses (length 2-8)
     * @param _A Amplification coefficient (typically 100-2000)
     * @param _fee Trading fee in 1e10 precision (4000000 = 0.04%)
     * @param _offpeg_fee_multiplier Multiplier for fee when off-peg (0 = disabled)
     * @param _ma_exp_time Moving average time window in seconds
     * @param _implementation_idx Index of the implementation to use (0 for basic)
     * @param _asset_types Array indicating asset type for each coin (0 = standard)
     * @param _method_ids Array of method IDs for rate oracles (bytes4(0) if none)
     * @param _oracles Array of oracle addresses (address(0) if none)
     * @return Address of the deployed pool
     */
    function deploy_plain_pool(
        string memory _name,
        string memory _symbol,
        address[] memory _coins,
        uint256 _A,
        uint256 _fee,
        uint256 _offpeg_fee_multiplier,
        uint256 _ma_exp_time,
        uint256 _implementation_idx,
        uint8[] memory _asset_types,
        bytes4[] memory _method_ids,
        address[] memory _oracles
    ) external returns (address);

    /**
     * @notice Get the number of available implementations
     */
    function pool_count() external view returns (uint256);

    /**
     * @notice Get pool address by index
     */
    function pool_list(uint256 _index) external view returns (address);

    /**
     * @notice Find pool for given coins
     */
    function find_pool_for_coins(address _from, address _to) external view returns (address);

    /**
     * @notice Get admin of the factory
     */
    function admin() external view returns (address);

    /**
     * @notice Get fee receiver
     */
    function fee_receiver() external view returns (address);
}

/**
 * @title ICurveStableSwapNG
 * @notice Interface for Curve StableSwap NG pools (deployed by factory)
 * @dev These pools use uint256 indices and have additional features
 */
interface ICurveStableSwapNG {
    /**
     * @notice Exchange tokens
     * @param i Index of input coin
     * @param j Index of output coin
     * @param dx Amount of input coin
     * @param min_dy Minimum amount of output coin
     * @param receiver Address to receive output
     * @return Actual output amount
     */
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy,
        address receiver
    ) external returns (uint256);

    /**
     * @notice Get expected output amount
     */
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    /**
     * @notice Add liquidity to the pool
     * @param amounts Array of amounts for each coin
     * @param min_mint_amount Minimum LP tokens to receive
     * @param receiver Address to receive LP tokens
     * @return Amount of LP tokens minted
     */
    function add_liquidity(
        uint256[] memory amounts,
        uint256 min_mint_amount,
        address receiver
    ) external returns (uint256);

    /**
     * @notice Add liquidity (alternate signature)
     */
    function add_liquidity(
        uint256[] memory amounts,
        uint256 min_mint_amount
    ) external returns (uint256);

    /**
     * @notice Remove liquidity
     * @param amount Amount of LP tokens to burn
     * @param min_amounts Minimum amounts of each coin to receive
     * @param receiver Address to receive coins
     * @return Array of amounts received
     */
    function remove_liquidity(
        uint256 amount,
        uint256[] memory min_amounts,
        address receiver
    ) external returns (uint256[] memory);

    /**
     * @notice Get pool balances
     */
    function balances(uint256 i) external view returns (uint256);

    /**
     * @notice Get coin address
     */
    function coins(uint256 i) external view returns (address);

    /**
     * @notice Get number of coins
     */
    function N_COINS() external view returns (uint256);

    /**
     * @notice Get amplification coefficient
     */
    function A() external view returns (uint256);

    /**
     * @notice Get fee
     */
    function fee() external view returns (uint256);

    /**
     * @notice Get LP token total supply (pool is also the LP token)
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Get LP token balance
     */
    function balanceOf(address account) external view returns (uint256);
}
