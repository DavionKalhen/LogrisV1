// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title DeleverageUnit
/// @notice Comprehensive unit tests for V3Leverager.deleverage() and vault withdrawal path 3.

import "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "../src/LeveragedVault.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
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
// Test-specific mocks
// ============================================================================

/// @dev Flash loan adapter where isTokenSupported always returns false
contract UnsupportedTokenFlashLoan is IFlashLoanAdapter {
    function flashLoan(address, uint256, address, bytes calldata) external override {}
    function getFlashLoanFee(address, uint256) external pure override returns (uint256) { return 0; }
    function isTokenSupported(address) external pure override returns (bool) { return false; }
    function maxFlashLoan(address) external pure override returns (uint256) { return 0; }
    function getProvider() external view override returns (address) { return address(this); }
}

/// @dev Converter whose underlyingToken differs from the vault's
contract MismatchedConverter is ITokenConverter {
    address public override yieldToken;
    address public override underlyingToken;
    constructor(address _underlying, address _yield) {
        underlyingToken = _underlying;
        yieldToken = _yield;
    }
    function toYield(uint256, address, uint256) external pure override returns (uint256) { return 0; }
    function toUnderlying(uint256, address, uint256) external pure override returns (uint256) { return 0; }
    function previewToYield(uint256) external pure override returns (uint256) { return 0; }
    function previewToUnderlying(uint256) external pure override returns (uint256) { return 0; }
}

// ============================================================================
// V3Leverager Deleverage Unit Tests
// ============================================================================

contract V3LeveragerDeleverageTest is Test {
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

    // ========== Helpers ==========

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

    function _buildParams(
        uint256 flashLoanAmount,
        uint256 withdrawAmount,
        uint256 burnAmount,
        uint256 minOutput
    ) internal view returns (ILeveragerV3.DeleverageParams memory) {
        return ILeveragerV3.DeleverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            recipient: alice,
            withdrawAmount: withdrawAmount,
            flashLoanAmount: flashLoanAmount,
            burnAmount: burnAmount,
            minOutput: minOutput
        });
    }

    // ========== Success ==========

    function test_Deleverage_SuccessfulCycle() public {
        _setupPosition(10 ether, 4 ether);
        uint256 posId = vault.getVaultPositionId();

        // flash 3 WETH → swap to 2.97 debt → burn → withdraw 5 yield → convert → repay → surplus
        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);

        uint256 aliceBalBefore = weth.balanceOf(alice);
        leverager.deleverage(params);

        // S-05 fix: only burnAmount (2 ether) is burned, not all debtReceived (2.97 ether)
        uint256 debtSwapOutput = 3 ether * 99 / 100; // 2.97 ether from mock swapper
        uint256 debtSurplus = debtSwapOutput - 2 ether; // 0.97 ether surplus debt → sent to alice
        assertEq(alchemist.posDebt(posId), 4 ether - 2 ether, "debt decreased by burnAmount only");
        assertEq(alchemist.posCollateral(posId), 5 ether, "collateral decreased");
        assertEq(weth.balanceOf(alice) - aliceBalBefore, 2 ether, "alice got underlying surplus");
        assertEq(debtToken.balanceOf(alice), debtSurplus, "alice got debt token surplus");
    }

    function test_Deleverage_EmitsEvent() public {
        _setupPosition(10 ether, 4 ether);
        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);

        vm.expectEmit(true, true, false, true);
        emit ILeveragerV3.DeleverageExecuted(
            address(vault), alice, 5 ether, 3 ether * 99 / 100, 2 ether
        );
        leverager.deleverage(params);
    }

    function test_Deleverage_StateResetAfterSuccess() public {
        _setupPosition(10 ether, 4 ether);
        leverager.deleverage(_buildParams(3 ether, 5 ether, 2 ether, 1 ether));

        // Second deleverage should work (state reset to Idle)
        uint256 posId = vault.getVaultPositionId();
        alchemist.mint(posId, 2 ether, address(this));
        leverager.deleverage(_buildParams(1 ether, 2 ether, 0.5 ether, 0.5 ether));
    }

    function test_Deleverage_ZeroSurplus() public {
        // Withdraw exactly flashLoanAmount worth → surplus = 0
        _setupPosition(10 ether, 4 ether);
        // flash 3, withdraw 3 yield → convert 3 → repay 3 → surplus 0
        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 3 ether, 2 ether, 0);

        uint256 aliceBalBefore = weth.balanceOf(alice);
        leverager.deleverage(params);
        assertEq(weth.balanceOf(alice) - aliceBalBefore, 0, "zero surplus");
    }

    // ========== Callback Validation ==========

    function test_OnFlashLoanReceived_RevertsNotInFlashLoan() public {
        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        leverager.onFlashLoanReceived(address(leverager), address(weth), 1 ether, 0, "");
    }

    // ========== Input Validation Errors ==========

    function test_Deleverage_RevertsUnapprovedConverter() public {
        _setupPosition(10 ether, 4 ether);
        AuditMockConverter bad = new AuditMockConverter(address(weth), address(yieldToken));

        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.converter = address(bad);

        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.deleverage(params);
    }

    function test_Deleverage_RevertsUnapprovedFlashLoanAdapter() public {
        _setupPosition(10 ether, 4 ether);
        AuditMockFlashLoan bad = new AuditMockFlashLoan();

        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.flashLoanAdapter = address(bad);

        vm.expectRevert(V3Leverager.UnapprovedFlashLoanAdapter.selector);
        leverager.deleverage(params);
    }

    function test_Deleverage_RevertsUnapprovedSwapper() public {
        _setupPosition(10 ether, 4 ether);
        AuditMockSwapper bad = new AuditMockSwapper(address(debtToken), address(weth));

        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.swapper = address(bad);

        vm.expectRevert(V3Leverager.UnapprovedSwapper.selector);
        leverager.deleverage(params);
    }

    function test_Deleverage_RevertsFlashLoanRequired() public {
        _setupPosition(10 ether, 4 ether);

        vm.expectRevert(V3Leverager.FlashLoanRequired.selector);
        leverager.deleverage(_buildParams(0, 5 ether, 2 ether, 1 ether));
    }

    function test_Deleverage_RevertsInvalidConverterTokens() public {
        _setupPosition(10 ether, 4 ether);
        AuditMockERC20 wrongToken = new AuditMockERC20("Wrong", "WRG");
        MismatchedConverter bad = new MismatchedConverter(address(wrongToken), address(yieldToken));

        vm.prank(owner);
        leverager.setConverterApproval(address(bad), true);

        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.converter = address(bad);

        vm.expectRevert(V3Leverager.InvalidConverterTokens.selector);
        leverager.deleverage(params);
    }

    function test_Deleverage_RevertsUnsupportedFlashLoanToken() public {
        _setupPosition(10 ether, 4 ether);
        UnsupportedTokenFlashLoan bad = new UnsupportedTokenFlashLoan();

        vm.prank(owner);
        leverager.setFlashLoanAdapterApproval(address(bad), true);

        ILeveragerV3.DeleverageParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.flashLoanAdapter = address(bad);

        vm.expectRevert(V3Leverager.UnsupportedFlashLoanToken.selector);
        leverager.deleverage(params);
    }

    // ========== Slippage & Output Errors ==========

    function test_Deleverage_RevertsSlippageExceeded_BurnAmount() public {
        _setupPosition(10 ether, 4 ether);
        // Swap gives 2.97 debt (3 * 99/100). Set burnAmount=2.98 → 2.97 < 2.98 → revert
        vm.expectRevert(V3Leverager.SlippageExceeded.selector);
        leverager.deleverage(_buildParams(3 ether, 5 ether, 2.98 ether, 0));
    }

    function test_Deleverage_RevertsSlippageExceeded_MinOutput() public {
        _setupPosition(10 ether, 4 ether);
        // underlyingReceived=5 (from converting 5 yield). Set minOutput=6 → 5 < 6 → revert
        vm.expectRevert(V3Leverager.SlippageExceeded.selector);
        leverager.deleverage(_buildParams(3 ether, 5 ether, 2 ether, 6 ether));
    }

    function test_Deleverage_RevertsInsufficientOutput() public {
        _setupPosition(10 ether, 8 ether);
        // flash 6, swap→5.94 debt, burn, withdraw 3 yield → convert 3 → repay 6: 3 < 6 → revert
        vm.expectRevert(V3Leverager.InsufficientOutput.selector);
        leverager.deleverage(_buildParams(6 ether, 3 ether, 1 ether, 0));
    }
}

// ============================================================================
// Vault Deleverage Integration Tests (withdrawal path 3)
// ============================================================================

contract VaultDeleverageIntegrationTest is Test {
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

    function test_WithdrawUnderlying_Path3_Deleverage() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        // Use the vault's own parameter calculator
        (uint256 flashLoanAmount, uint256 burnAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(halfShares, 100, 200);

        assertTrue(burnAmount > 0, "should be path 3");

        uint256 aliceBalBefore = weth.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawUnderlying(halfShares, flashLoanAmount, burnAmount, minUnderlyingOut);

        assertTrue(weth.balanceOf(alice) > aliceBalBefore, "alice received underlying");
        assertEq(vault.balanceOf(alice), shares - halfShares, "shares burned");
    }

    function test_WithdrawUnderlyingAtomic_WithDebt() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        uint256 halfShares = shares / 2;

        uint256 aliceBalBefore = weth.balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(halfShares, 100, 200);

        assertGt(withdrawn, 0, "non-zero withdrawal");
        assertGt(weth.balanceOf(alice), aliceBalBefore, "alice received underlying");
        assertEq(vault.balanceOf(alice), shares - halfShares, "shares burned");
    }

    function test_GetWithdrawParams_Path1_PoolSufficient() public {
        // Deposit only (no leverage) — pool retains all funds
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        uint256 shares = vault.balanceOf(alice);
        (uint256 flashLoanAmount, uint256 burnAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        assertEq(flashLoanAmount, 0, "path 1: no flash loan");
        assertEq(burnAmount, 0, "path 1: no burn");
        assertEq(minUnderlyingOut, 10 ether, "path 1: exact amount");
    }

    function test_GetWithdrawParams_Path2_FreeCapacity() public {
        // Leverage with no debt → freeWithdrawCapacity = full collateral
        _setupPosition(10 ether, 0);
        assertEq(vault.getDepositPoolBalance(), 0);

        uint256 shares = vault.balanceOf(alice) / 4;
        (uint256 flashLoanAmount, uint256 burnAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        assertEq(flashLoanAmount, 0, "path 2: no flash loan");
        assertEq(burnAmount, 0, "path 2: no burn");
        assertGt(minUnderlyingOut, 0, "path 2: slippage-adjusted output");
    }

    function test_VaultDeleveraged_EmitsEvent() public {
        _setupPosition(10 ether, 4 ether);
        uint256 halfShares = vault.balanceOf(alice) / 2;

        (uint256 flashLoanAmount, uint256 burnAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(halfShares, 100, 200);

        vm.expectEmit(false, false, false, true);
        emit LeveragedVault.VaultDeleveraged(halfShares, burnAmount);

        vm.prank(alice);
        vault.withdrawUnderlying(halfShares, flashLoanAmount, burnAmount, minUnderlyingOut);
    }
}
