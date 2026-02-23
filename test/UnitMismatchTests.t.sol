// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "./LogrisTestBase.t.sol";

/// @title UnitMismatchTests
/// @notice Tests vault behavior when the MYT-to-underlying conversion rate is not 1:1.
///         Uses real AlchemistV3 and VaultV2 (MYT) with simulated yield accrual to create
///         a ~2:1 MYT-to-underlying conversion rate.
///
/// @dev Yield accrual is simulated by:
///      1. Depositing 100e18 underlying into VaultV2 to get 100e18 MYT at 1:1 rate
///      2. Transferring 100e18 extra underlying to the MockYieldToken (simulating yield)
///      3. Setting VaultV2 maxRate to MAX_MAX_RATE (200% APR) and warping 1 year forward
///         so the rate cap allows the VaultV2 to recognize the doubled underlying balance
///      After this setup, 1 MYT ≈ 2 underlying.
contract UnitMismatchTests is LogrisTestBase {
    using stdStorage for StdStorage;

    /// @dev MAX_MAX_RATE from VaultV2 ConstantsLib: 200% APR per second
    uint256 constant MAX_MAX_RATE = 200e16 / uint256(365 days);

    function setUp() public {
        _deployLogrisStack();

        // 1. Fund initial MYT: deposit 100 underlying -> 100 MYT shares, allocated to strategy
        _fundWithMYT(address(this), 100 ether);

        // 2. Simulate yield: double the underlying held by MockYieldToken
        //    MockYieldToken now has 200e18 underlying for 100e18 yield shares -> price = 2e18
        //    MockMYTStrategy.realAssets() = yieldShares * yieldToken.price() / 1e18 = 100e18 * 2 = 200e18
        underlying.mint(address(yieldToken), 100 ether);

        // 3. Set VaultV2 maxRate to allow the share price to reflect the yield increase
        //    VaultV2.setMaxRate requires msg.sender to be an isAllocator address
        vm.prank(address(allocator));
        mytVault.setMaxRate(MAX_MAX_RATE);

        // 4. Warp forward 1 year so maxTotalAssets grows enough to cover the 100% yield increase
        //    At MAX_MAX_RATE (200% APR), after 1 year: maxGrowth = 200%, realAssets = 200e18
        //    maxTotalAssets = 100e18 + 200e18 = 300e18 > 200e18, so newTotalAssets = 200e18
        vm.warp(block.timestamp + 365 days);

        // NOTE: The rate sanity check cannot be done here in setUp() because VaultV2 uses
        // transient storage (firstTotalAssets) that prevents re-accrual within the same tx.
        // The rate is correct in test functions because each test runs as a new EVM call
        // where transient storage is cleared.

        // 5. Set deposit cap on AlchemistV3 (in MYT terms)
        _setDepositCap(80 ether);
    }

    /// @dev Stores a vaultPositionId of 1 and mocks getCDP to return specific values.
    function _setupMockPosition(uint256 collateral, uint256 debt) internal {
        // Set vault position ID via stdstore
        uint256 slot = stdstore.target(address(vault)).sig("vaultPositionId()").find();
        vm.store(address(vault), bytes32(slot), bytes32(uint256(1)));

        // Mock getCDP to return specific collateral/debt/earmarked values
        vm.mockCall(
            address(alchemist),
            abi.encodeWithSelector(alchemist.getCDP.selector, uint256(1)),
            abi.encode(collateral, debt, uint256(0))
        );
    }

    /// @notice Sanity check: verifies the MYT-to-underlying rate is approximately 2:1 after yield accrual.
    function testYieldRateIsApproximately2To1() public {
        uint256 rate = alchemist.convertYieldTokensToUnderlying(1 ether);
        assertApproxEqAbs(rate, 2 ether, 10, "1 MYT should convert to approximately 2 underlying");

        uint256 inverseRate = alchemist.convertUnderlyingTokensToYield(2 ether);
        assertApproxEqAbs(inverseRate, 1 ether, 10, "2 underlying should convert to approximately 1 MYT");
    }

    /// @notice Tests that getVaultRedeemableBalance converts yield tokens to underlying correctly.
    /// @dev With 100 MYT collateral at 2:1 rate = ~200 underlying, minus 40 debt, plus 50 pool = ~210
    function testRedeemableBalanceUsesUnderlyingValue() public {
        _setupMockPosition(100 ether, 40 ether);

        // Add pool balance
        underlying.mint(address(vault), 50 ether);

        uint256 redeemable = vault.getVaultRedeemableBalance();

        // Expected: collateral_in_underlying - debt + pool
        // = convertYieldTokensToUnderlying(100e18) - 40e18 + 50e18
        uint256 collateralUnderlying = alchemist.convertYieldTokensToUnderlying(100 ether);
        uint256 expected = collateralUnderlying - 40 ether + 50 ether;

        assertApproxEqAbs(redeemable, expected, 10, "redeemable should reflect 2:1 conversion");
        // Verify the ballpark is correct (~210 ether)
        assertApproxEqAbs(redeemable, 210 ether, 0.01 ether, "redeemable should be approximately 210 ether");
    }

    /// @notice Tests that getFreeWithdrawCapacity accounts for non-1:1 yield-to-underlying conversion.
    /// @dev With 100 MYT collateral at 2:1 rate = ~200 underlying, 40 debt, minCollat = ~1.111
    ///      free = 200 - 40 * 1.111 = ~155.556
    function testFreeWithdrawCapacityUsesUnderlyingValue() public {
        _setupMockPosition(100 ether, 40 ether);

        uint256 free = vault.getFreeWithdrawCapacity();

        // Expected: collateral_underlying - debt * minimumCollateralization / 1e18
        uint256 collateralUnderlying = alchemist.convertYieldTokensToUnderlying(100 ether);
        uint256 minCollat = alchemist.minimumCollateralization();
        uint256 lockedCollateral = 40 ether * minCollat / 1e18;
        uint256 expected = collateralUnderlying - lockedCollateral;

        assertApproxEqAbs(free, expected, 10, "free withdraw capacity should reflect 2:1 conversion");
        // With 1.111x collateralization: free ≈ 200 - 44.44 ≈ 155.56
        assertApproxEqAbs(free, 155.555 ether, 0.01 ether, "free should be approximately 155.56 ether");
    }

    /// @notice Tests that getTotalWithdrawCapacity converts collateral to underlying correctly.
    /// @dev With 100 MYT collateral at 2:1 rate, total capacity = ~200 underlying
    function testTotalWithdrawCapacityUsesUnderlyingValue() public {
        _setupMockPosition(100 ether, 0);

        uint256 total = vault.getTotalWithdrawCapacity();

        uint256 expected = alchemist.convertYieldTokensToUnderlying(100 ether);
        assertApproxEqAbs(total, expected, 10, "total capacity should reflect 2:1 conversion");
        assertApproxEqAbs(total, 200 ether, 0.01 ether, "total capacity should be approximately 200 ether");
    }

    /// @notice Tests that getLeverageParameters clamps deposit to available yield capacity.
    /// @dev With deposit cap = 80 MYT and 2:1 rate, capacity = ~160 underlying.
    ///      Requesting 200 underlying should be clamped to ~160.
    function testLeverageParametersClampByYieldCapacity() public {
        // Call with 0 slippage for deterministic values
        (uint256 clampedDeposit, uint256 flashLoanAmount, uint256 underlyingDepositMin,,) =
            vault.getLeverageParameters(200 ether, 0, 0);

        // depositCapacity = 80 MYT (cap=80, totalDeposited=0)
        // expectedYieldFromDeposit = convertUnderlyingTokensToYield(200e18) ≈ 100 MYT
        // Since 80 < 100, we enter the clamping branch:
        //   clampedDeposit = convertYieldTokensToUnderlying(80) ≈ 160
        //   underlyingDepositMin = 80 (0 slippage applied to 80 MYT capacity)
        //   flashLoanAmount = 0
        uint256 expectedClamped = alchemist.convertYieldTokensToUnderlying(80 ether);
        assertApproxEqAbs(clampedDeposit, expectedClamped, 10, "clampedDeposit should equal capacity in underlying");
        assertApproxEqAbs(clampedDeposit, 160 ether, 0.01 ether, "clampedDeposit should be approximately 160 ether");
        assertEq(flashLoanAmount, 0, "flashLoanAmount should be 0 when clamped");
        assertEq(underlyingDepositMin, 80 ether, "underlyingDepositMin should equal MYT capacity");
    }
}
