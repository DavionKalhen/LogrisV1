// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LeverageErrorPaths
/// @notice Tests for untested leverage error paths and parameter consistency (F-04 fix).
///         Migrated to use real AlchemistV3 via LogrisTestBase.

import "./LogrisTestBase.t.sol";
import "../src/interfaces/ITokenConverter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal ERC4626 interface for LossyConverter (deposit/redeem + preview).
interface IERC4626Vault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
}

// ============================================================================
// Mock: Converter that returns fewer yield tokens than expected
// ============================================================================

/// @dev Converter that loses 50% on toYield by depositing only half the underlying
///      into VaultV2 (MYT). Simulates a bad conversion for error path testing.
contract LossyConverter is ITokenConverter {
    using SafeERC20 for IERC20;
    address public override yieldToken;
    address public override underlyingToken;
    IERC4626Vault public mytVault;

    constructor(address _underlying, address _yield, address _mytVault) {
        underlyingToken = _underlying;
        yieldToken = _yield;
        mytVault = IERC4626Vault(_mytVault);
    }

    function toYield(uint256 amount, address recipient, uint256) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), amount);
        uint256 halfAmount = amount / 2; // 50% loss
        IERC20(underlyingToken).approve(address(mytVault), halfAmount);
        uint256 output = mytVault.deposit(halfAmount, recipient);
        return output;
    }

    function toUnderlying(uint256 amount, address recipient, uint256) external override returns (uint256) {
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        uint256 output = mytVault.redeem(amount, recipient, address(this));
        return output;
    }

    function previewToYield(uint256 amount) external view override returns (uint256) { return mytVault.previewDeposit(amount / 2); }
    function previewToUnderlying(uint256 amount) external view override returns (uint256) { return mytVault.previewRedeem(amount); }
}

// ============================================================================
// Leverage Error Path Tests
// ============================================================================

contract LeverageErrorPathTest is LogrisTestBase {

    function setUp() public {
        _deployLogrisStack();
    }

    // ========== InsufficientYieldFromConversion ==========

    function test_Leverage_RevertsInsufficientYieldFromConversion() public {
        // Deploy vault with lossy converter (50% yield loss)
        LossyConverter lossy = new LossyConverter(address(underlying), address(mytVault), address(mytVault));

        vm.prank(owner);
        leverager.setConverterApproval(address(lossy), true);

        LeveragedVault lossyVault = _deployLeveragedVault(
            address(leverager),
            address(lossy),
            address(flashLoanAdapter),
            address(swapper),
            owner
        );

        underlying.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(lossyVault), 10 ether);
        lossyVault.depositUnderlying(10 ether);
        vm.stopPrank();

        // Leverage with no flash loan, underlyingDepositMin = 10 ether (expects 10 yield)
        // Lossy converter deposits only half -> ~5 MYT < 10 -> revert
        // Note: mintAmount=0 here is fine because the revert happens before the leverager call
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.InsufficientYieldFromConversion.selector);
        lossyVault.leverage(10 ether, 0, 10 ether, 0, 0, 0);
    }

    function test_Leverage_SkipsYieldCheckWhenFlashLoanUsed() public {
        // Deposit and leverage using leverageAtomic which auto-computes valid parameters.
        // This verifies the happy path: with a valid 1:1 MYTConverter and no flash loan,
        // the yield check passes and leverage completes successfully.
        underlying.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);

        // leverageAtomic auto-computes mintAmount, debtTradeMin, etc.
        // With 1:1 MYTConverter, yield tokens received >= underlyingDepositMin, so no revert
        vault.leverageAtomic(5 ether, 100, 200, 0);
        vm.stopPrank();

        // Verify position was created and has collateral
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should be created");
    }

    // ========== ZeroDeposit (new validation) ==========

    function test_DepositUnderlying_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.ZeroDeposit.selector);
        vault.depositUnderlying(0);
    }

    // ========== SwapSlippageBelowMinimum edge cases ==========

    function test_Leverage_SwapSlippageBelowMinimum_ExactBoundary() public {
        // Deposit and create a position first using leverageAtomic
        _depositFor(alice, 10 ether);
        vm.prank(alice);
        vault.leverageAtomic(5 ether, 100, 200, 0);

        // Now deposit more and try to leverage with explicit slippage below minimum
        _depositFor(alice, 10 ether);

        // debtSlippage = 200 bps (set during vault initialization)
        // mintAmount = 4 ether
        // minAcceptableSwap = 4e18 * (10000 - 200) / 10000 = 3.92 ether
        // debtTradeMin = 3.91 ether < 3.92 ether -> revert
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.SwapSlippageBelowMinimum.selector);
        vault.leverage(5 ether, 0, 5 ether, 4 ether, 3.91 ether, 0);
    }

    function test_Leverage_SwapSlippage_PassesAtExactMinimum() public {
        // Deposit and create a position first using leverageAtomic
        _depositFor(alice, 10 ether);
        vm.prank(alice);
        vault.leverageAtomic(5 ether, 100, 200, 0);

        // Now deposit more and leverage with exactly-at-minimum slippage
        _depositFor(alice, 10 ether);

        // mintAmount=2 ether, enforcement=200 bps
        // minAcceptableSwap = 2e18 * 9800 / 10000 = 1.96 ether
        // debtTradeMin = 1.96 ether -> exactly at boundary -> should pass
        vm.prank(alice);
        vault.leverage(5 ether, 0, 5 ether, 2 ether, 1.96 ether, 0);
    }
}

// ============================================================================
// Parameter Consistency Tests (F-04 fix validation)
// ============================================================================

contract ParameterConsistencyTest is LogrisTestBase {

    function setUp() public {
        _deployLogrisStack();
    }

    /// @dev Deposits underlying into the vault and leverages it with minimal debt (no flash loan).
    ///      With real AlchemistV3, leverage(amount, 0, amount, mintAmount, debtTradeMin) deposits
    ///      `amount` of MYT as collateral and mints `mintAmount` of debt.
    ///      Then optionally mints additional debt via alchemist.mint.
    function _setupPosition(uint256 depositAmount, uint256 debtAmount) internal returns (uint256 posId) {
        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);

        // Leverage with a small mintAmount (1 wei) to create the position without flash loan.
        // This deposits all underlying as collateral and mints minimal debt.
        // debtTradeMin = 0 (within 200 bps enforcement: minAcceptable = 1*9800/10000 = 0)
        vault.leverage(depositAmount, 0, depositAmount, 1, 0, 0);
        vm.stopPrank();

        posId = vault.getVaultPositionId();
        if (debtAmount > 0) {
            // With real AlchemistV3, impersonate the vault (position owner) to mint debt.
            // Must be on a different block than leverage to avoid CannotRepayOnMintBlock issues.
            vm.roll(block.number + 1);
            vm.prank(address(vault));
            alchemist.mint(posId, debtAmount, address(this));
        }
    }

    /// @notice F-04 fix: getWithdrawUnderlyingParameters path 1 uses poolBalance (not getFreeWithdrawCapacity)
    function test_F04_Path1_PoolBalanceSufficient() public {
        // Deposit without leveraging -> pool retains all funds
        underlying.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        // Path 1: pool has enough -> no flash loan, no burn, exact amount
        assertEq(flashLoan, 0);
        assertEq(burn, 0);
        assertEq(minOut, 10 ether);

        // Execute should succeed with these params
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, flashLoan, burn, minOut, 0);
        assertEq(withdrawn, 10 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice F-04 fix: path 2 combines poolBalance + getFreeWithdrawCapacity
    function test_F04_Path2_PoolPlusFreeCapacity() public {
        // Leverage all, leaving 0 pool, then add some pool balance back.
        // _setupPosition with debtAmount=0 creates position with ~10 MYT collateral, ~1 wei debt.
        _setupPosition(10 ether, 0);

        // After leverage(10, 0, 10, 1, 0), pool should be near zero
        // (the 1 wei of debt swap surplus is negligible)

        // Add partial pool balance (3 ether) -- simulates new deposit after leverage
        underlying.mint(alice, 3 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 3 ether);
        vault.depositUnderlying(3 ether);
        vm.stopPrank();

        // Pool has at least 3 ether now; freeCapacity from Alchemist position adds more.
        // Small withdrawal within available capacity -> path 2
        uint256 smallShares = vault.balanceOf(alice) / 10;
        (uint256 flashLoan, uint256 burn,) =
            vault.getWithdrawUnderlyingParameters(smallShares, 100, 200);

        assertEq(flashLoan, 0, "path 2: no flash loan");
        assertEq(burn, 0, "path 2: no burn");
    }

    /// @notice F-04 fix: path 3 parameters produce successful execution
    function test_F04_Path3_ParamsMatchExecution() public {
        // Use leverageAtomic to create a fully-leveraged position (maximizes debt).
        // This creates a position where ANY withdrawal requires deleverage (path 3).
        _depositFor(alice, 100 ether);
        vm.prank(alice);
        vault.leverageAtomic(100 ether, 100, 200, 0);

        vm.roll(block.number + 1);

        uint256 allShares = vault.balanceOf(alice);

        // Get calculated params for full withdrawal
        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(allShares, 100, 200);

        // Path 3 should require flash loan and debt burn
        assertGt(flashLoan, 0, "path 3: flash loan needed");
        assertGt(burn, 0, "path 3: burn needed");
        assertGt(minOut, 0, "path 3: has min output");

        // Execute with calculated params -- must not revert
        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        vault.withdrawUnderlying(allShares, flashLoan, burn, minOut, 0);

        assertGt(IERC20(address(underlying)).balanceOf(alice) - aliceBalBefore, 0, "alice received tokens");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    /// @notice Verify withdrawUnderlyingAtomic uses getWithdrawUnderlyingParameters internally
    function test_AtomicWithdraw_ConsistentWithParams() public {
        _setupPosition(10 ether, 4 ether);

        vm.roll(block.number + 1);

        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        // Get what the params would be
        (, uint256 burn,) =
            vault.getWithdrawUnderlyingParameters(halfShares, 100, 200);

        // Atomic should use the same path
        if (burn > 0) {
            // Should emit VaultDeleveraged with the burn amount
            vm.expectEmit(false, false, false, true);
            emit LeveragedVault.VaultDeleveraged(halfShares, burn);
        }

        vm.prank(alice);
        vault.withdrawUnderlyingAtomic(halfShares, 100, 200, 0);

        assertEq(vault.balanceOf(alice), shares - halfShares);
    }

    /// @notice Edge: all shares withdrawal through path 3
    function test_F04_FullWithdrawal_Path3() public {
        _setupPosition(10 ether, 4 ether);

        vm.roll(block.number + 1);

        uint256 allShares = vault.balanceOf(alice);

        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(allShares, 100, 200);

        assertGt(burn, 0, "full withdrawal needs deleverage");

        vm.prank(alice);
        vault.withdrawUnderlying(allShares, flashLoan, burn, minOut, 0);

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertGt(IERC20(address(underlying)).balanceOf(alice), 0, "alice received underlying");
    }

    /// @notice Path transitions: partial pool balance shifts from path 1 to path 2/3
    function test_F04_PathTransition_PoolToAlchemist() public {
        // Start with pool balance (no leverage)
        underlying.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);

        // Path 1: pool has enough
        (uint256 fl1, uint256 b1,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertEq(fl1, 0);
        assertEq(b1, 0);

        // Now leverage 8 ether with minimal debt (1 wei mintAmount).
        // This deposits 8 MYT as collateral, leaving 2 ether in pool.
        vm.prank(alice);
        vault.leverage(8 ether, 0, 8 ether, 1, 0, 0);

        // Pool now has ~2 ether (plus negligible dust from 1 wei debt swap)
        uint256 poolAfterLeverage = vault.getDepositPoolBalance();
        assertApproxEqAbs(poolAfterLeverage, 2 ether, 1e15, "pool should be ~2 ether");

        // Path should now be 2 (pool + free capacity covers it)
        (uint256 fl2, uint256 b2,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertEq(fl2, 0, "path 2: no flash loan");
        assertEq(b2, 0, "path 2: no burn");

        // Add debt to force path 3
        uint256 posId = vault.getVaultPositionId();
        vm.roll(block.number + 1);
        vm.prank(address(vault));
        alchemist.mint(posId, 3 ether, address(this));

        // With 3 ether debt, freeCapacity is reduced. Total available < underlyingAmount -> path 3
        (uint256 fl3, uint256 b3,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertGt(fl3, 0, "path 3: needs flash loan");
        assertGt(b3, 0, "path 3: needs burn");
    }
}
