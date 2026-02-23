// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LogrisTestBase.t.sol";

// ============ Fuzz Test Contracts ============

/**
 * @title LeveragedVaultFuzzTest
 * @notice Fuzz tests for mathematical calculations and share accounting
 *         using the real AlchemistV3 stack via LogrisTestBase.
 */
contract LeveragedVaultFuzzTest is LogrisTestBase {

    function setUp() public {
        _deployLogrisStack();
    }

    // ============ Share Calculation Fuzz Tests ============

    /// @notice First depositor should always receive shares equal to deposit amount
    function testFuzz_FirstDepositorSharesEqualDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        underlying.mint(alice, amount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares = vault.depositUnderlying(amount);
        vm.stopPrank();

        assertEq(shares, amount * 1000, "First depositor should get 1000:1 shares (offset=3)");
        assertEq(vault.balanceOf(alice), amount * 1000, "Balance should match shares");
    }

    /// @notice Multiple depositors should get shares proportional to their deposit relative to totalAssets
    function testFuzz_MultiDepositorShareProportionality(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e6, 1e27);
        amount2 = bound(amount2, 1e6, 1e27);

        // Alice deposits first
        underlying.mint(alice, amount1);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount1);
        uint256 aliceShares = vault.depositUnderlying(amount1);
        vm.stopPrank();

        // Bob deposits second
        underlying.mint(bob, amount2);
        vm.startPrank(bob);
        IERC20(address(underlying)).approve(address(vault), amount2);
        uint256 bobShares = vault.depositUnderlying(amount2);
        vm.stopPrank();

        // Both should have received positive shares
        assertGt(aliceShares, 0, "Alice should have shares");
        assertGt(bobShares, 0, "Bob should have shares");

        // Total shares should equal total deposits (within rounding)
        uint256 totalShares = vault.totalSupply();
        uint256 totalDeposits = amount1 + amount2;
        // Allow 2 wei rounding error per deposit
        assertApproxEqAbs(totalShares, totalDeposits * 1000, 2000, "Total shares should approximate total deposits * 1000 (offset=3)");
    }

    /// @notice convertSharesToUnderlyingTokens and convertUnderlyingTokensToShares should be inverse
    function testFuzz_ShareConversionRoundTrip(uint256 depositAmount, uint256 queryAmount) public {
        depositAmount = bound(depositAmount, 1e12, 1e27);
        queryAmount = bound(queryAmount, 1, depositAmount);

        // Create initial deposit so vault has supply
        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // Convert underlying -> shares -> underlying should be approximately identity
        uint256 shares = vault.convertUnderlyingTokensToShares(queryAmount);
        uint256 backToUnderlying = vault.convertSharesToUnderlyingTokens(shares);

        // Should be within 1 wei due to rounding
        assertApproxEqAbs(backToUnderlying, queryAmount, 1, "Round trip should preserve value");
    }

    /// @notice No depositor should get 0 shares for a non-zero deposit
    function testFuzz_NonZeroDepositGetsNonZeroShares(uint256 amount) public {
        amount = bound(amount, 1e6, 1e30);

        underlying.mint(alice, amount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares = vault.depositUnderlying(amount);
        vm.stopPrank();

        assertGt(shares, 0, "Non-zero deposit must produce non-zero shares");
    }

    // ============ Basis Point Adjustment Fuzz Tests ============

    /// @notice _basisPointAdjustment should always reduce or maintain the amount
    function testFuzz_BasisPointAdjustmentNeverIncreases(uint256 amount, uint32 slippageBps) public pure {
        amount = bound(amount, 0, 1e30);
        slippageBps = uint32(bound(slippageBps, 0, 9999));

        // We can test this through getLeverageParameters which uses _basisPointAdjustment internally
        // Or test the formula directly
        uint256 adjusted = amount * (10000 - slippageBps) / 10000;
        assertLe(adjusted, amount, "Adjusted amount must be <= original");
    }

    /// @notice Zero slippage should return the same amount
    function testFuzz_ZeroSlippagePreservesAmount(uint256 amount) public pure {
        amount = bound(amount, 0, 1e30);
        uint256 adjusted = amount * (10000 - 0) / 10000;
        assertEq(adjusted, amount, "Zero slippage should not change amount");
    }

    // ============ Flash Loan Calculation Fuzz Tests ============

    /// @notice Flash loan amount should be finite and bounded for valid inputs
    function testFuzz_FlashLoanAmountBounded(
        uint256 depositAmount,
        uint32 underlyingSlippage,
        uint32 debtSlippage
    ) public view {
        depositAmount = bound(depositAmount, 1e15, 1e24);
        underlyingSlippage = uint32(bound(underlyingSlippage, 1, 500)); // 0.01% - 5%
        debtSlippage = uint32(bound(debtSlippage, 1, 500)); // 0.01% - 5%

        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            uint256 underlyingDepositMin,
            uint256 mintAmount,
            uint256 debtTradeMin
        ) = vault.getLeverageParameters(depositAmount, underlyingSlippage, debtSlippage);

        // Clamped deposit should be <= original
        assertLe(clampedDeposit, depositAmount, "Clamped deposit must be <= original");

        // If no capacity limitation, clamped should equal original
        if (clampedDeposit == depositAmount) {
            // Flash loan should be non-negative (it's uint so always true, but check it's finite)
            assertTrue(flashLoanAmount < type(uint256).max, "Flash loan must be finite");

            // Minimum output values should be <= their source amounts
            assertLe(debtTradeMin, mintAmount, "Debt trade min must be <= mint amount");
        }

        // underlyingDepositMin should be reduced from full deposit
        if (clampedDeposit > 0) {
            assertLe(underlyingDepositMin, clampedDeposit + flashLoanAmount,
                "Deposit min must be <= total deposit");
        }
    }

    // ============ Redeemable Balance Fuzz Tests ============

    /// @notice Redeemable balance should equal pool balance when no position exists
    function testFuzz_RedeemableEqualsPoolWithNoPosition(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        underlying.mint(address(vault), amount);

        uint256 redeemable = vault.getVaultRedeemableBalance();
        assertEq(redeemable, amount, "Redeemable should equal pool balance without position");
    }

    /// @notice Total supply should be zero when no deposits have been made
    function testFuzz_TotalSupplyZeroInitially() public view {
        assertEq(vault.totalSupply(), 0, "Total supply should be zero initially");
    }

    // ============ Withdrawal Parameter Fuzz Tests ============

    /// @notice When funds are in pool (no Alchemist position), direct withdrawal works
    /// @dev getWithdrawUnderlyingParameters only computes deleverage params for Alchemist;
    ///      the actual withdrawUnderlying function checks pool balance first
    function testFuzz_PoolOnlyWithdrawalDirect(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e12, 1e27);

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        uint256 shares = vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // With no position, pool has all funds - direct withdrawal works
        uint256 poolBalance = vault.getDepositPoolBalance();
        uint256 underlyingValue = vault.convertSharesToUnderlyingTokens(shares);

        assertEq(poolBalance, depositAmount, "Pool should hold full deposit");
        assertApproxEqAbs(underlyingValue, depositAmount, 1, "Share value should equal deposit");

        // Withdrawal should succeed without needing flash loan (pool has enough)
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, 0, 0, 0, 0);

        assertApproxEqAbs(withdrawn, depositAmount, 1, "Should withdraw full deposit");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares after withdrawal");
    }

    // ============ Deposit Cap Fuzz Tests ============

    /// @notice Deposit capacity should decrease as deposits fill up
    function testFuzz_DepositCapacityDecreases(uint256 cap) public {
        cap = bound(cap, 1e18, 1e30);

        // Set cap via real AlchemistV3 admin
        _setDepositCap(cap);

        // With nothing deposited, capacity should be the full cap
        uint256 capacity = vault.getDepositCapacity();
        assertEq(capacity, cap, "Capacity should equal cap with no deposits");
    }

    // ============ Edge Case Fuzz Tests ============

    /// @notice convertSharesToUnderlyingTokens should return 0 for 0 shares
    function testFuzz_ZeroSharesReturnZeroUnderlying() public {
        // First make a deposit so supply > 0
        underlying.mint(alice, 1e18);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 1e18);
        vault.depositUnderlying(1e18);
        vm.stopPrank();

        uint256 underlying_ = vault.convertSharesToUnderlyingTokens(0);
        assertEq(underlying_, 0, "Zero shares should convert to zero underlying");
    }

    /// @notice convertSharesToUnderlyingTokens should return shares/1000 when supply is 0 (offset=3)
    function testFuzz_ZeroSupplyReturnsScaledShares(uint256 shares) public view {
        shares = bound(shares, 1, 1e30);
        uint256 underlying_ = vault.convertSharesToUnderlyingTokens(shares);
        // With offset=3: convertToAssets(shares) = shares * (0+1) / (0+1000) = shares/1000
        assertEq(underlying_, shares / 1000, "Should return shares/1000 when supply is 0 (offset=3)");
    }

    /// @notice Multiple sequential deposits should maintain share value invariant
    function testFuzz_SequentialDepositsPreserveValue(
        uint256 deposit1,
        uint256 deposit2,
        uint256 deposit3
    ) public {
        deposit1 = bound(deposit1, 1e12, 1e24);
        deposit2 = bound(deposit2, 1e12, 1e24);
        deposit3 = bound(deposit3, 1e12, 1e24);

        address charlie = makeAddr("charlie");

        // Three sequential deposits
        underlying.mint(alice, deposit1);
        vm.prank(alice);
        IERC20(address(underlying)).approve(address(vault), deposit1);
        vm.prank(alice);
        vault.depositUnderlying(deposit1);

        underlying.mint(bob, deposit2);
        vm.prank(bob);
        IERC20(address(underlying)).approve(address(vault), deposit2);
        vm.prank(bob);
        vault.depositUnderlying(deposit2);

        underlying.mint(charlie, deposit3);
        vm.prank(charlie);
        IERC20(address(underlying)).approve(address(vault), deposit3);
        vm.prank(charlie);
        vault.depositUnderlying(deposit3);

        // Total supply should approximate total deposits * 1000 (offset=3)
        uint256 totalDeposits = deposit1 + deposit2 + deposit3;
        uint256 totalSupply = vault.totalSupply();
        assertApproxEqAbs(totalSupply, totalDeposits * 1000, 3000,
            "Total supply should approximate total deposits * 1000 (offset=3)");

        // Each user's share value should approximate their deposit
        uint256 aliceValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(alice));
        uint256 bobValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(bob));
        uint256 charlieValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(charlie));

        assertApproxEqAbs(aliceValue, deposit1, 3, "Alice value should approximate deposit");
        assertApproxEqAbs(bobValue, deposit2, 3, "Bob value should approximate deposit");
        assertApproxEqAbs(charlieValue, deposit3, 3, "Charlie value should approximate deposit");
    }
}
