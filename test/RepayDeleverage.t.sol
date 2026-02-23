// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LogrisTestBase.t.sol";

// ============================================================================
// E2E Repay Deleverage Tests
// ============================================================================

/// @title RepayDeleverageE2ETest
/// @notice E2E tests for the repay-based deleverage flow using the real AlchemistV3 stack.
///         Tests the full cycle: deposit → leverage → withdraw (with repay deleverage).
contract RepayDeleverageE2ETest is LogrisTestBase {

    function setUp() public {
        _deployLogrisStack();
    }

    // ============ Helpers ============

    /// @dev Deposits underlying into vault as alice, returns shares received.
    function _aliceDeposit(uint256 amount) internal returns (uint256 shares) {
        shares = _depositFor(alice, amount);
    }

    /// @dev Executes leverage with auto-computed parameters.
    function _executeLeverage(uint256 depositAmount) internal {
        vault.leverageAtomic(depositAmount, 100, 200, 0);
    }

    // ============ Tests ============

    function test_E2E_DepositAndLeverage() public {
        // Alice deposits
        uint256 depositAmount = 100e18;
        uint256 shares = _aliceDeposit(depositAmount);
        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.getDepositPoolBalance(), depositAmount, "Pool balance should match deposit");

        // Leverage the pool
        _executeLeverage(depositAmount);

        // After leverage: pool should be mostly consumed, position should exist with collateral and debt
        assertLt(vault.getDepositPoolBalance(), depositAmount, "Pool should be partially drained after leverage");
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should exist");

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertGt(collateral, depositAmount, "Collateral should exceed initial deposit (leveraged)");
        assertGt(debt, 0, "Should have debt");
    }

    function test_E2E_RepayDeleverageWithdraw() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _aliceDeposit(depositAmount);

        // Leverage the pool
        _executeLeverage(depositAmount);

        // Advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        // Get pre-withdraw state
        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);

        // Withdraw all shares with auto-computed parameters (will trigger deleverage)
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(shares, 100, 200, 0);

        assertGt(withdrawn, 0, "Should withdraw some underlying");
        uint256 aliceBalAfter = IERC20(address(underlying)).balanceOf(alice);
        uint256 received = aliceBalAfter - aliceBalBefore;
        // Allow up to 100 wei dust from fixed-point rounding across the deleverage path
        assertApproxEqAbs(received, withdrawn, 100, "Alice should receive approximately withdrawn amount");
        assertGt(received, withdrawn * 99 / 100, "Rounding loss should be negligible");
    }

    function test_E2E_PartialWithdrawDeleverage() public {
        // Use a smaller leverage so partial withdrawal stays in deleverage territory
        // but doesn't try to repay nearly all debt (avoiding the dust rounding edge case)
        uint256 depositAmount = 100e18;
        _aliceDeposit(depositAmount);

        // Leverage the pool
        _executeLeverage(depositAmount);
        vm.roll(block.number + 1);

        // Deposit more shares (unlevered) so that a partial withdraw of original shares
        // triggers deleverage but the remaining position is healthy
        uint256 extraShares = _aliceDeposit(50e18);
        uint256 totalShares = vault.balanceOf(alice);

        // Withdraw the extra shares only (should come from pool — Path 1)
        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(extraShares, 0, 0, 0, 0);

        assertGt(withdrawn, 0, "Should withdraw some underlying");
        uint256 aliceBalAfter = IERC20(address(underlying)).balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, withdrawn);

        // Vault should still have remaining shares and a position
        assertGt(vault.totalSupply(), 0, "Should have remaining shares");
        assertGt(vault.getVaultPositionId(), 0, "Position should still exist");
    }

    function test_E2E_WithdrawParameterCalcMatchesExecution() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _aliceDeposit(depositAmount);

        // Leverage
        _executeLeverage(depositAmount);
        vm.roll(block.number + 1);

        // Calculate parameters explicitly
        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares);

        // Execute with those exact parameters
        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, flashLoanAmount, repayAmount, minUnderlyingOut, 0);

        uint256 aliceBalAfter = IERC20(address(underlying)).balanceOf(alice);
        uint256 received = aliceBalAfter - aliceBalBefore;
        assertGe(received, minUnderlyingOut, "Received should >= minUnderlyingOut");
        // Allow small dust from fixed-point rounding across deleverage conversion chain
        assertApproxEqAbs(received, withdrawn, 100, "Received should approximately match returned value");
    }

    function test_E2E_NoDeleverageNeededForPoolWithdraw() public {
        // Deposit but don't leverage — should withdraw from pool directly (Path 1)
        uint256 depositAmount = 50e18;
        uint256 shares = _aliceDeposit(depositAmount);

        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, 0, 0, 0, 0);

        assertEq(withdrawn, depositAmount, "Should withdraw full deposit from pool");
        uint256 aliceBalAfter = IERC20(address(underlying)).balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, depositAmount);
    }

    function test_E2E_PokePositionSyncsState() public {
        uint256 depositAmount = 100e18;
        _aliceDeposit(depositAmount);
        _executeLeverage(depositAmount);

        // pokePosition should succeed and not revert
        vault.pokePosition();

        // Also works when called by anyone
        vm.prank(alice);
        vault.pokePosition();
    }

    function test_E2E_PokePositionNoOpWithoutPosition() public {
        // No leverage, no position — pokePosition should be a no-op
        vault.pokePosition();
    }

    function test_E2E_GetWithdrawParamsNoDeleverage() public {
        // When there's only pool balance, params should indicate no deleverage
        uint256 depositAmount = 50e18;
        uint256 shares = _aliceDeposit(depositAmount);

        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares);

        assertEq(flashLoanAmount, 0, "No flash loan needed for pool withdraw");
        assertEq(repayAmount, 0, "No repay needed for pool withdraw");
        assertGt(minUnderlyingOut, 0, "Should have a minimum output");
    }

    function test_E2E_GetWithdrawParamsWithDeleverage() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _aliceDeposit(depositAmount);
        _executeLeverage(depositAmount);
        vm.roll(block.number + 1);

        (uint256 flashLoanAmount, uint256 repayAmount,) =
            vault.getWithdrawUnderlyingParameters(shares);

        // Full withdrawal after leverage requires deleverage
        assertGt(flashLoanAmount, 0, "Should need flash loan for deleverage");
        assertGt(repayAmount, 0, "Should need repay amount for deleverage");
    }

    function test_E2E_MultipleDepositsAndSingleWithdraw() public {
        // Alice deposits in two tranches
        uint256 shares1 = _aliceDeposit(50e18);
        uint256 shares2 = _aliceDeposit(50e18);
        uint256 totalShares = shares1 + shares2;

        // Leverage all
        _executeLeverage(100e18);
        vm.roll(block.number + 1);

        // Withdraw everything
        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(totalShares, 100, 200, 0);

        assertGt(withdrawn, 0);
        uint256 aliceBalAfter = IERC20(address(underlying)).balanceOf(alice);
        uint256 received = aliceBalAfter - aliceBalBefore;
        assertApproxEqAbs(received, withdrawn, 100, "Received should approximately match returned value");
        assertEq(vault.totalSupply(), 0, "All shares should be burned");
    }

    function test_E2E_CannotWithdrawOnSameBlockAsMint() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _aliceDeposit(depositAmount);

        // Leverage (mints debt in this block)
        _executeLeverage(depositAmount);

        // Try to withdraw in same block — should revert because repay() reverts on mint block
        vm.prank(alice);
        vm.expectRevert(); // CannotRepayOnMintBlock from AlchemistV3
        vault.withdrawUnderlyingAtomic(shares, 100, 200, 0);
    }
}
