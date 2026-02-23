// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/interfaces/ISwapper.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ICurveStETHPool {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function fee() external view returns (uint256);
}

/**
 * @title CurveStETHSwapper
 * @notice Test swapper that integrates with Curve stETH/ETH pool
 * @dev Used to validate Curve integration pattern with a liquid pool
 */
contract CurveStETHSwapper is ISwapper, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;

    // Curve stETH/ETH pool
    address public constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // Pool indices: 0 = ETH, 1 = stETH
    int128 constant ETH_INDEX = 0;
    int128 constant STETH_INDEX = 1;

    uint256 public slippageTolerance = 100; // 1%

    constructor(address _owner) Ownable(_owner) {}

    // For this test, debtToken = stETH, underlyingToken = WETH
    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256 minUnderlyingOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256 underlyingReceived) {
        if (debtAmount == 0) revert InvalidAmount();
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer stETH from sender
        IERC20(STETH).safeTransferFrom(msg.sender, address(this), debtAmount);

        // Approve pool to spend stETH
        IERC20(STETH).approve(CURVE_POOL, debtAmount);

        // Get expected output
        uint256 expectedEth = ICurveStETHPool(CURVE_POOL).get_dy(STETH_INDEX, ETH_INDEX, debtAmount);
        uint256 minEthOut = minUnderlyingOut > 0
            ? minUnderlyingOut
            : (expectedEth * (BASIS_POINTS - slippageTolerance)) / BASIS_POINTS;

        // Execute swap: stETH -> ETH
        uint256 ethReceived = ICurveStETHPool(CURVE_POOL).exchange(
            STETH_INDEX,
            ETH_INDEX,
            debtAmount,
            minEthOut
        );

        // Wrap ETH -> WETH
        IWETH(WETH).deposit{value: ethReceived}();

        // Transfer WETH to recipient
        IERC20(WETH).safeTransfer(recipient, ethReceived);

        emit SwapExecuted(STETH, WETH, debtAmount, ethReceived, recipient);
        return ethReceived;
    }

    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256 minDebtOut,
        address recipient,
        bytes calldata
    ) external override returns (uint256 debtReceived) {
        if (underlyingAmount == 0) revert InvalidAmount();
        if (recipient == address(0)) recipient = msg.sender;

        // Transfer WETH from sender
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), underlyingAmount);

        // Unwrap WETH -> ETH
        IWETH(WETH).withdraw(underlyingAmount);

        // Get expected output
        uint256 expectedSteth = ICurveStETHPool(CURVE_POOL).get_dy(ETH_INDEX, STETH_INDEX, underlyingAmount);
        uint256 minStethOut = minDebtOut > 0
            ? minDebtOut
            : (expectedSteth * (BASIS_POINTS - slippageTolerance)) / BASIS_POINTS;

        // Execute swap: ETH -> stETH
        debtReceived = ICurveStETHPool(CURVE_POOL).exchange{value: underlyingAmount}(
            ETH_INDEX,
            STETH_INDEX,
            underlyingAmount,
            minStethOut
        );

        // Transfer stETH to recipient
        IERC20(STETH).safeTransfer(recipient, debtReceived);

        emit SwapExecuted(WETH, STETH, underlyingAmount, debtReceived, recipient);
        return debtReceived;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external view override returns (uint256 expectedUnderlying, uint256 minimumOutput)
    {
        if (debtAmount == 0) return (0, 0);
        expectedUnderlying = ICurveStETHPool(CURVE_POOL).get_dy(STETH_INDEX, ETH_INDEX, debtAmount);
        minimumOutput = (expectedUnderlying * (BASIS_POINTS - slippageTolerance)) / BASIS_POINTS;
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external view override returns (uint256 expectedDebt, uint256 minimumOutput)
    {
        if (underlyingAmount == 0) return (0, 0);
        expectedDebt = ICurveStETHPool(CURVE_POOL).get_dy(ETH_INDEX, STETH_INDEX, underlyingAmount);
        minimumOutput = (expectedDebt * (BASIS_POINTS - slippageTolerance)) / BASIS_POINTS;
    }

    function getDebtToUnderlyingRate() external view override returns (uint256) {
        return ICurveStETHPool(CURVE_POOL).get_dy(STETH_INDEX, ETH_INDEX, PRECISION);
    }

    function getUnderlyingToDebtRate() external view override returns (uint256) {
        return ICurveStETHPool(CURVE_POOL).get_dy(ETH_INDEX, STETH_INDEX, PRECISION);
    }

    function getSwapFee() external view override returns (uint256) {
        return ICurveStETHPool(CURVE_POOL).fee() / 1e6; // Convert from 1e10 to basis points
    }

    function getSlippageTolerance() external view override returns (uint256) {
        return slippageTolerance;
    }

    function isSupportedPair(address tokenA, address tokenB) external pure override returns (bool) {
        return (tokenA == STETH && tokenB == WETH) || (tokenA == WETH && tokenB == STETH);
    }

    receive() external payable {}
}

/**
 * @title CurveSwapperForkTest
 * @notice Fork tests for Curve swapper against mainnet pools
 * @dev Uses stETH/ETH pool which has high liquidity
 */
contract CurveSwapperForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    CurveStETHSwapper public swapper;
    address public alice = makeAddr("alice");
    address public owner = makeAddr("owner");

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000); // Use specific block for consistency

        swapper = new CurveStETHSwapper(owner);

        // Fund alice with ETH and WETH
        vm.deal(alice, 200 ether);
        vm.prank(alice);
        (bool success,) = WETH.call{value: 100 ether}("");
        require(success, "WETH deposit failed");

        // Get stETH for alice by swapping through Curve
        vm.startPrank(alice);
        uint256 expectedSteth = ICurveStETHPool(CURVE_STETH_POOL).get_dy(0, 1, 50 ether);
        ICurveStETHPool(CURVE_STETH_POOL).exchange{value: 50 ether}(0, 1, 50 ether, expectedSteth * 95 / 100);
        vm.stopPrank();
    }

    // ============ Configuration Tests ============

    function test_SwapperConfiguration() public view {
        assertEq(swapper.getSlippageTolerance(), 100);
    }

    function test_IsSupportedPair() public view {
        assertTrue(swapper.isSupportedPair(STETH, WETH));
        assertTrue(swapper.isSupportedPair(WETH, STETH));
        assertFalse(swapper.isSupportedPair(STETH, address(0)));
    }

    // ============ Preview Tests ============

    function test_PreviewSwapDebtToUnderlying() public view {
        uint256 stethAmount = 1 ether;
        (uint256 expected, uint256 minimum) = swapper.previewSwapDebtToUnderlying(stethAmount);

        assertTrue(expected > 0, "Should have expected output");
        assertTrue(minimum < expected, "Minimum should be less than expected");
        // stETH should be close to 1:1 with ETH
        assertTrue(expected > 0.95 ether && expected < 1.05 ether, "Rate should be near 1:1");
    }

    function test_PreviewSwapUnderlyingToDebt() public view {
        uint256 wethAmount = 1 ether;
        (uint256 expected, uint256 minimum) = swapper.previewSwapUnderlyingToDebt(wethAmount);

        assertTrue(expected > 0, "Should have expected output");
        // ETH should get slightly more stETH (stETH trades at slight discount)
        assertTrue(expected >= 0.99 ether, "Should get at least 0.99 stETH");
    }

    // ============ Swap Execution Tests ============

    function test_SwapDebtToUnderlying() public {
        uint256 stethAmount = 1 ether;

        uint256 aliceStethBefore = IERC20(STETH).balanceOf(alice);
        uint256 aliceWethBefore = IERC20(WETH).balanceOf(alice);

        require(aliceStethBefore >= stethAmount, "Alice needs more stETH");

        (uint256 expectedWeth,) = swapper.previewSwapDebtToUnderlying(stethAmount);

        vm.startPrank(alice);
        IERC20(STETH).approve(address(swapper), stethAmount);
        uint256 wethReceived = swapper.swapDebtToUnderlying(
            stethAmount,
            expectedWeth * 95 / 100,
            alice,
            ""
        );
        vm.stopPrank();

        uint256 aliceStethAfter = IERC20(STETH).balanceOf(alice);
        uint256 aliceWethAfter = IERC20(WETH).balanceOf(alice);

        // Note: stETH uses shares, so balance diff might not be exact
        assertTrue(aliceStethBefore > aliceStethAfter, "Should spend stETH");
        assertEq(aliceWethAfter - aliceWethBefore, wethReceived, "Should receive WETH");
        assertTrue(wethReceived > 0.9 ether, "Should receive ~1 WETH");
    }

    function test_SwapUnderlyingToDebt() public {
        uint256 wethAmount = 1 ether;

        uint256 aliceStethBefore = IERC20(STETH).balanceOf(alice);
        uint256 aliceWethBefore = IERC20(WETH).balanceOf(alice);

        require(aliceWethBefore >= wethAmount, "Alice needs more WETH");

        (uint256 expectedSteth,) = swapper.previewSwapUnderlyingToDebt(wethAmount);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(swapper), wethAmount);
        uint256 stethReceived = swapper.swapUnderlyingToDebt(
            wethAmount,
            expectedSteth * 95 / 100,
            alice,
            ""
        );
        vm.stopPrank();

        uint256 aliceStethAfter = IERC20(STETH).balanceOf(alice);
        uint256 aliceWethAfter = IERC20(WETH).balanceOf(alice);

        assertEq(aliceWethBefore - aliceWethAfter, wethAmount, "Should spend WETH");
        assertTrue(stethReceived > 0.99 ether, "Should receive ~1 stETH");
    }

    // ============ Rate Tests ============

    function test_GetExchangeRates() public view {
        uint256 debtToUnderlying = swapper.getDebtToUnderlyingRate();
        uint256 underlyingToDebt = swapper.getUnderlyingToDebtRate();

        // Rates should be close to 1:1
        assertTrue(debtToUnderlying > 0.95e18 && debtToUnderlying < 1.05e18, "stETH->ETH should be ~1:1");
        assertTrue(underlyingToDebt > 0.99e18, "ETH->stETH should be >= 0.99");
    }

    function test_GetSwapFee() public view {
        uint256 fee = swapper.getSwapFee();
        assertTrue(fee <= 50, "Fee should be <= 0.5%");
    }

    // ============ Edge Cases ============

    function test_SwapZeroAmountReverts() public {
        vm.expectRevert(ISwapper.InvalidAmount.selector);
        swapper.swapDebtToUnderlying(0, 0, alice, "");
    }

    // ============ Integration with Flash Loan ============

    function test_FlashLoanThenSwap() public {
        // This simulates the leverage flow:
        // 1. Flash loan WETH
        // 2. Swap WETH -> stETH (debt token)
        // This validates the swap works as part of a leverage cycle

        uint256 flashLoanAmount = 10 ether;

        // Simulate receiving flash loan
        vm.deal(address(this), flashLoanAmount);
        (bool success,) = WETH.call{value: flashLoanAmount}("");
        require(success, "WETH deposit failed");

        // Approve and swap
        IERC20(WETH).approve(address(swapper), flashLoanAmount);
        (uint256 expectedSteth,) = swapper.previewSwapUnderlyingToDebt(flashLoanAmount);

        uint256 stethReceived = swapper.swapUnderlyingToDebt(
            flashLoanAmount,
            expectedSteth * 95 / 100,
            address(this),
            ""
        );

        assertTrue(stethReceived > flashLoanAmount * 99 / 100, "Should receive ~same amount of stETH");
    }
}
