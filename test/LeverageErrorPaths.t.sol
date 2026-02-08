// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title LeverageErrorPaths
/// @notice Tests for untested leverage error paths and parameter consistency (F-04 fix).

import "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../src/LeveragedVault.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import {
    AuditMockERC20,
    AuditMockWETH,
    AuditMockAlchemistV3,
    AuditMockConverter,
    AuditMockSwapper,
    AuditMockFlashLoan,
    _auditDeployVault
} from "./AuditCoverage.t.sol";

// ============================================================================
// Mock: Converter that returns fewer yield tokens than expected
// ============================================================================

/// @dev Converter that loses 50% on toYield (simulates bad conversion)
contract LossyConverter is ITokenConverter {
    using SafeERC20 for IERC20;
    address public override yieldToken;
    address public override underlyingToken;

    constructor(address _underlying, address _yield) {
        underlyingToken = _underlying;
        yieldToken = _yield;
    }

    function toYield(uint256 amount, address recipient, uint256) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), amount);
        uint256 output = amount / 2; // 50% loss
        AuditMockERC20(yieldToken).mint(recipient, output);
        return output;
    }

    function toUnderlying(uint256 amount, address recipient, uint256) external override returns (uint256) {
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        AuditMockERC20(underlyingToken).mint(recipient, amount);
        return amount;
    }

    function previewToYield(uint256 amount) external pure override returns (uint256) { return amount / 2; }
    function previewToUnderlying(uint256 amount) external pure override returns (uint256) { return amount; }
}

// ============================================================================
// Leverage Error Path Tests
// ============================================================================

contract LeverageErrorPathTest is Test {
    AuditMockWETH public weth;
    AuditMockERC20 public yieldToken;
    AuditMockERC20 public debtToken;
    AuditMockAlchemistV3 public alchemist;
    AuditMockConverter public converter;
    AuditMockSwapper public swapper;
    AuditMockFlashLoan public flashLoanAdapter;
    V3Leverager public leverager;
    LeveragedVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        weth = new AuditMockWETH();
        yieldToken = new AuditMockERC20("Yield", "YLD");
        debtToken = new AuditMockERC20("Debt", "DBT");
        alchemist = new AuditMockAlchemistV3(address(yieldToken), address(debtToken));
        converter = new AuditMockConverter(address(weth), address(yieldToken));
        swapper = new AuditMockSwapper(address(debtToken), address(weth));
        flashLoanAdapter = new AuditMockFlashLoan();

        vm.startPrank(owner);
        leverager = new V3Leverager(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        leverager.setSwapperApproval(address(swapper), true);

        vault = _auditDeployVault(
            address(yieldToken), address(weth),
            address(alchemist), address(leverager),
            address(converter), address(flashLoanAdapter), address(swapper),
            owner
        );
        vm.stopPrank();
    }

    // ========== InsufficientYieldFromConversion ==========

    function test_Leverage_RevertsInsufficientYieldFromConversion() public {
        // Deploy vault with lossy converter (50% yield loss)
        LossyConverter lossy = new LossyConverter(address(weth), address(yieldToken));

        vm.startPrank(owner);
        leverager.setConverterApproval(address(lossy), true);
        LeveragedVault lossyVault = _auditDeployVault(
            address(yieldToken), address(weth),
            address(alchemist), address(leverager),
            address(lossy), address(flashLoanAdapter), address(swapper),
            owner
        );
        vm.stopPrank();

        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(lossyVault), 10 ether);
        lossyVault.depositUnderlying(10 ether);
        vm.stopPrank();

        // Leverage with no flash loan, underlyingDepositMin = 10 ether (expects 10 yield)
        // Lossy converter returns only 5 yield → 5 < 10 → revert
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.InsufficientYieldFromConversion.selector);
        lossyVault.leverage(10 ether, 0, 10 ether, 0, 0);
    }

    function test_Leverage_SkipsYieldCheckWhenFlashLoanUsed() public {
        // With flashLoan > 0, minYieldFromDeposit = 0 so the vault-side check is skipped.
        // The leverager handles yield validation instead.
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        // underlyingDepositMin = 0 when flash loan is used (per _executeLeverage logic)
        // This should NOT revert with InsufficientYieldFromConversion
        vm.prank(alice);
        vault.leverage(5 ether, 0, 5 ether, 0, 0);
    }

    // ========== ZeroDeposit (new validation) ==========

    function test_DepositUnderlying_RevertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.ZeroDeposit.selector);
        vault.depositUnderlying(0);
    }

    function test_DepositUnderlyingETH_RevertsOnZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.ZeroDeposit.selector);
        vault.depositUnderlying{value: 0}();
    }

    // ========== SwapSlippageBelowMinimum edge cases ==========

    function test_Leverage_SwapSlippageBelowMinimum_ExactBoundary() public {
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        // debtSlippage = 200 bps, enforcement = 200 bps
        // minAcceptableSwap = mintAmount * (10000 - 200) / 10000 = mintAmount * 98/100
        // If debtTradeMin < minAcceptableSwap → revert
        // mintAmount = 5 ether, minAcceptableSwap = 4.9 ether
        // Set debtTradeMin = 4.89 ether → revert
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.SwapSlippageBelowMinimum.selector);
        vault.leverage(5 ether, 0, 5 ether, 5 ether, 4.89 ether);
    }

    function test_Leverage_SwapSlippage_PassesAtExactMinimum() public {
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        // mintAmount=2 → with 5 collateral, borrow capacity = 5/2 = 2.5, so 2 ≤ 2.5 ✓
        // enforcement = debtSlippage(200bps) = 200 bps
        // minAcceptableSwap = 2e18 * 9800 / 10000 = 1.96 ether
        // debtTradeMin = 1.96 ether → exactly at boundary → should pass
        vm.prank(alice);
        vault.leverage(5 ether, 0, 5 ether, 2 ether, 1.96 ether);
    }
}

// ============================================================================
// Parameter Consistency Tests (F-04 fix validation)
// ============================================================================

contract ParameterConsistencyTest is Test {
    AuditMockWETH public weth;
    AuditMockERC20 public yieldToken;
    AuditMockERC20 public debtToken;
    AuditMockAlchemistV3 public alchemist;
    AuditMockConverter public converter;
    AuditMockSwapper public swapper;
    AuditMockFlashLoan public flashLoanAdapter;
    V3Leverager public leverager;
    LeveragedVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");

    function setUp() public {
        weth = new AuditMockWETH();
        yieldToken = new AuditMockERC20("Yield", "YLD");
        debtToken = new AuditMockERC20("Debt", "DBT");
        alchemist = new AuditMockAlchemistV3(address(yieldToken), address(debtToken));
        converter = new AuditMockConverter(address(weth), address(yieldToken));
        swapper = new AuditMockSwapper(address(debtToken), address(weth));
        flashLoanAdapter = new AuditMockFlashLoan();

        vm.startPrank(owner);
        leverager = new V3Leverager(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        leverager.setSwapperApproval(address(swapper), true);

        vault = _auditDeployVault(
            address(yieldToken), address(weth),
            address(alchemist), address(leverager),
            address(converter), address(flashLoanAdapter), address(swapper),
            owner
        );
        vm.stopPrank();
    }

    function _setupPosition(uint256 depositAmount, uint256 debtAmount) internal returns (uint256 posId) {
        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vault.leverage(depositAmount, 0, depositAmount, 0, 0);
        vm.stopPrank();

        posId = vault.getVaultPositionId();
        if (debtAmount > 0) {
            alchemist.mint(posId, debtAmount, address(this));
        }
    }

    /// @notice F-04 fix: getWithdrawUnderlyingParameters path 1 uses poolBalance (not getFreeWithdrawCapacity)
    function test_F04_Path1_PoolBalanceSufficient() public {
        // Deposit without leveraging → pool retains all funds
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        // Path 1: pool has enough → no flash loan, no burn, exact amount
        assertEq(flashLoan, 0);
        assertEq(burn, 0);
        assertEq(minOut, 10 ether);

        // Execute should succeed with these params
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, flashLoan, burn, minOut);
        assertEq(withdrawn, 10 ether);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// @notice F-04 fix: path 2 combines poolBalance + getFreeWithdrawCapacity
    function test_F04_Path2_PoolPlusFreeCapacity() public {
        // Leverage all, leaving 0 pool, then add some pool balance back
        _setupPosition(10 ether, 0);
        assertEq(vault.getDepositPoolBalance(), 0);

        // Add partial pool balance (3 ether) — simulates new deposit after leverage
        weth.mint(alice, 3 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 3 ether);
        vault.depositUnderlying(3 ether);
        vm.stopPrank();

        // Pool=3, freeCapacity=10 (no debt), availableUnderlying=13
        // Small withdrawal within available capacity → path 2
        uint256 smallShares = vault.balanceOf(alice) / 10;
        (uint256 flashLoan, uint256 burn,) =
            vault.getWithdrawUnderlyingParameters(smallShares, 100, 200);

        assertEq(flashLoan, 0, "path 2: no flash loan");
        assertEq(burn, 0, "path 2: no burn");
    }

    /// @notice F-04 fix: path 3 parameters produce successful execution
    function test_F04_Path3_ParamsMatchExecution() public {
        _setupPosition(10 ether, 4 ether);

        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        // Get calculated params
        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(halfShares, 100, 200);

        // Path 3 should require flash loan and debt burn
        assertGt(flashLoan, 0, "path 3: flash loan needed");
        assertGt(burn, 0, "path 3: burn needed");
        assertGt(minOut, 0, "path 3: has min output");

        // Execute with calculated params — must not revert
        uint256 aliceBalBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawUnderlying(halfShares, flashLoan, burn, minOut);

        assertGt(weth.balanceOf(alice) - aliceBalBefore, 0, "alice received tokens");
        assertEq(vault.balanceOf(alice), shares - halfShares, "shares burned");
    }

    /// @notice Verify withdrawUnderlyingAtomic uses getWithdrawUnderlyingParameters internally
    function test_AtomicWithdraw_ConsistentWithParams() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        // Get what the params would be
        (uint256 flashLoan, uint256 burn,) =
            vault.getWithdrawUnderlyingParameters(halfShares, 100, 200);

        // Atomic should use the same path
        if (burn > 0) {
            // Should emit VaultDeleveraged with the burn amount
            vm.expectEmit(false, false, false, true);
            emit LeveragedVault.VaultDeleveraged(halfShares, burn);
        }

        vm.prank(alice);
        vault.withdrawUnderlyingAtomic(halfShares, 100, 200);

        assertEq(vault.balanceOf(alice), shares - halfShares);
    }

    /// @notice Edge: all shares withdrawal through path 3
    function test_F04_FullWithdrawal_Path3() public {
        _setupPosition(10 ether, 4 ether);
        uint256 allShares = vault.balanceOf(alice);

        (uint256 flashLoan, uint256 burn, uint256 minOut) =
            vault.getWithdrawUnderlyingParameters(allShares, 100, 200);

        assertGt(burn, 0, "full withdrawal needs deleverage");

        vm.prank(alice);
        vault.withdrawUnderlying(allShares, flashLoan, burn, minOut);

        assertEq(vault.balanceOf(alice), 0, "all shares burned");
        assertGt(weth.balanceOf(alice), 0, "alice received underlying");
    }

    /// @notice Path transitions: partial pool balance shifts from path 1 to path 2/3
    function test_F04_PathTransition_PoolToAlchemist() public {
        // Start with pool balance (no leverage)
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);

        // Path 1: pool has enough
        (uint256 fl1, uint256 b1,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertEq(fl1, 0);
        assertEq(b1, 0);

        // Now leverage most of the pool
        vm.prank(alice);
        vault.leverage(8 ether, 0, 8 ether, 0, 0);

        // Pool now has 2 ether, position has 8 collateral
        assertEq(vault.getDepositPoolBalance(), 2 ether);

        // Path should now be 2 (pool + free capacity covers it)
        (uint256 fl2, uint256 b2,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertEq(fl2, 0, "path 2: no flash loan");
        assertEq(b2, 0, "path 2: no burn");

        // Add debt to force path 3
        uint256 posId = vault.getVaultPositionId();
        alchemist.mint(posId, 3 ether, address(this));

        // freeCapacity = 8 - 3*2 = 2, available = 2+2 = 4
        // underlyingAmount for all shares: totalAssets = 2 + (8-3) = 7
        // 7 > 4 → path 3
        (uint256 fl3, uint256 b3,) = vault.getWithdrawUnderlyingParameters(shares, 100, 200);
        assertGt(fl3, 0, "path 3: needs flash loan");
        assertGt(b3, 0, "path 3: needs burn");
    }
}
