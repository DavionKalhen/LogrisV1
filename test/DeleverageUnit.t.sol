// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title DeleverageUnit
/// @notice Comprehensive unit tests for V3Leverager.deleverageRepay() and vault withdrawal path 3.
///         Uses real AlchemistV3 via LogrisTestBase instead of mock AlchemistV3.

import "./LogrisTestBase.t.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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

contract V3LeveragerDeleverageTest is LogrisTestBase {

    /// @dev ERC-7201 storage slot for LeveragedVault.vaultPositionId
    ///      Base = 0x66ffcd6e30a6e809fc5f771c6fbd297089c8842af4bafa5c4f2a8100b3cc4600
    ///      vaultPositionId is at offset +8 in the struct
    bytes32 constant VAULT_POSITION_ID_SLOT =
        bytes32(uint256(0x66ffcd6e30a6e809fc5f771c6fbd297089c8842af4bafa5c4f2a8100b3cc4600) + 8);

    function setUp() public {
        _deployLogrisStack();
    }

    // ========== Helpers ==========

    /// @dev Sets up a vault position with exact collateral and debt amounts.
    ///      Bypasses the leverage path (which always creates debt) to get precise control.
    ///      Deposits MYT directly to alchemist as the vault, then mints exact debt.
    function _setupPosition(uint256 depositAmount, uint256 debtAmount) internal returns (uint256 posId) {
        // 1. Give alice vault shares (represents her claim on the underlying)
        _depositFor(alice, depositAmount);

        // 2. Create MYT for the vault's alchemist position.
        //    Deposit to VaultV2 WITHOUT allocating to strategy so underlying stays idle
        //    in VaultV2 for later redemptions during deleverage.
        underlying.mint(address(this), depositAmount);
        IERC20(address(underlying)).approve(address(mytVault), depositAmount);
        uint256 mytShares = mytVault.deposit(depositAmount, address(this));

        // 3. Transfer MYT to vault, then vault deposits to alchemist (creating the position)
        IERC20(address(mytVault)).transfer(address(vault), mytShares);

        vm.startPrank(address(vault));
        IERC20(address(mytVault)).approve(address(alchemist), mytShares);
        alchemist.deposit(mytShares, address(vault), 0);
        vm.stopPrank();

        posId = positionNFT.tokenOfOwnerByIndex(address(vault), 0);

        // 4. Store position ID in vault's ERC-7201 namespaced storage
        vm.store(address(vault), VAULT_POSITION_ID_SLOT, bytes32(posId));

        // 5. Drain the vault's underlying pool balance to simulate post-leverage state
        //    (in real leverage, the pool underlying is converted to MYT and deposited)
        vm.prank(address(vault));
        underlying.transfer(address(0xDEAD), depositAmount);

        // 6. Mint exact debt amount if needed
        if (debtAmount > 0) {
            vm.prank(address(vault));
            alchemist.mint(posId, debtAmount, address(this));
            vm.roll(block.number + 1); // avoid CannotRepayOnMintBlock for subsequent repays
        }
    }

    function _buildParams(
        uint256 flashLoanAmount,
        uint256 withdrawAmount,
        uint256 repayAmount,
        uint256 minOutput
    ) internal view returns (ILeveragerV3.DeleverageRepayParams memory) {
        return ILeveragerV3.DeleverageRepayParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            recipient: alice,
            withdrawAmount: withdrawAmount,
            flashLoanAmount: flashLoanAmount,
            repayAmount: repayAmount,
            minOutput: minOutput
        });
    }

    // ========== Success ==========

    function test_DeleverageRepay_SuccessfulCycle() public {
        _setupPosition(10 ether, 4 ether);
        uint256 posId = vault.getVaultPositionId();

        // flash 3 WETH -> convert to 3 MYT (1:1) -> repay 2 MYT -> withdraw 5 MYT
        // surplus MYT = 3-2 = 1; total MYT = 1+5 = 6 -> convert to 6 underlying -> repay flash 3 -> surplus 3
        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);

        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);

        (uint256 collateral, uint256 debt, ) = alchemist.getCDP(posId);
        assertEq(debt, 2 ether, "debt decreased by repayAmount");
        assertEq(collateral, 5 ether, "collateral decreased");
        assertEq(
            IERC20(address(underlying)).balanceOf(alice) - aliceBalBefore,
            3 ether,
            "alice got underlying surplus"
        );
    }

    function test_DeleverageRepay_EmitsEvent() public {
        _setupPosition(10 ether, 4 ether);
        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);

        vm.expectEmit(true, true, false, true);
        emit ILeveragerV3.DeleverageRepayExecuted(
            address(vault), alice, 2 ether, 5 ether, 3 ether
        );
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
    }

    function test_DeleverageRepay_StateResetAfterSuccess() public {
        _setupPosition(10 ether, 4 ether);
        vm.prank(address(vault));
        leverager.deleverageRepay(_buildParams(3 ether, 5 ether, 2 ether, 1 ether));

        // After first deleverage: debt=2, collateral=5.
        // Mint 0.5 more debt so we can test a second deleverage.
        uint256 posId = vault.getVaultPositionId();
        vm.prank(address(vault));
        alchemist.mint(posId, 0.5 ether, address(this));
        vm.roll(block.number + 1); // avoid CannotRepayOnMintBlock

        // Second deleverageRepay should work (state reset to Idle)
        // debt=2.5, collateral=5. repay 0.5 -> debt=2, withdraw 1 -> collateral=4
        // locked after = 2 * 1.111 = 2.222 < 4 (OK)
        // flash=1 -> 1 MYT -> repay 0.5 -> surplus 0.5 MYT + withdraw 1 = 1.5 MYT -> 1.5 underlying -> repay 1 -> 0.5 surplus
        vm.prank(address(vault));
        leverager.deleverageRepay(_buildParams(1 ether, 1 ether, 0.5 ether, 0));
    }

    function test_DeleverageRepay_ZeroSurplus() public {
        // For zero surplus: surplus = (flashLoanAmount - repayAmount) + withdrawAmount - flashLoanAmount
        //                          = withdrawAmount - repayAmount
        // So need withdrawAmount == repayAmount.
        // flash 3 -> 3 MYT -> repay 2 -> surplus 1 MYT -> withdraw 2 MYT -> total 3 MYT -> 3 underlying -> repay 3 -> 0
        _setupPosition(10 ether, 4 ether);
        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 2 ether, 2 ether, 0);

        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
        assertEq(IERC20(address(underlying)).balanceOf(alice) - aliceBalBefore, 0, "zero surplus");
    }

    // ========== Callback Validation ==========

    function test_OnFlashLoanReceived_RevertsNotInFlashLoan() public {
        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        leverager.onFlashLoanReceived(address(leverager), address(underlying), 1 ether, 0, "");
    }

    // ========== Input Validation Errors ==========

    function test_DeleverageRepay_RevertsUnapprovedConverter() public {
        _setupPosition(10 ether, 4 ether);
        MYTConverter badConverter = new MYTConverter(address(mytVault), address(underlying));

        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.converter = address(badConverter);

        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
    }

    function test_DeleverageRepay_RevertsUnapprovedFlashLoanAdapter() public {
        _setupPosition(10 ether, 4 ether);
        LocalFlashLoanAdapter badAdapter = new LocalFlashLoanAdapter(address(underlying));

        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.flashLoanAdapter = address(badAdapter);

        vm.expectRevert(V3Leverager.UnapprovedFlashLoanAdapter.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
    }

    function test_DeleverageRepay_RevertsFlashLoanRequired() public {
        _setupPosition(10 ether, 4 ether);

        vm.expectRevert(V3Leverager.FlashLoanRequired.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(_buildParams(0, 5 ether, 2 ether, 1 ether));
    }

    function test_DeleverageRepay_RevertsInvalidConverterTokens() public {
        _setupPosition(10 ether, 4 ether);
        // Use a mismatched converter whose underlyingToken differs from vault's
        MismatchedConverter bad = new MismatchedConverter(address(0xDEAD), address(mytVault));

        vm.prank(owner);
        leverager.setConverterApproval(address(bad), true);

        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.converter = address(bad);

        vm.expectRevert(V3Leverager.InvalidConverterTokens.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
    }

    function test_DeleverageRepay_RevertsUnsupportedFlashLoanToken() public {
        _setupPosition(10 ether, 4 ether);
        UnsupportedTokenFlashLoan bad = new UnsupportedTokenFlashLoan();

        vm.prank(owner);
        leverager.setFlashLoanAdapterApproval(address(bad), true);

        ILeveragerV3.DeleverageRepayParams memory params = _buildParams(3 ether, 5 ether, 2 ether, 1 ether);
        params.flashLoanAdapter = address(bad);

        vm.expectRevert(V3Leverager.UnsupportedFlashLoanToken.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(params);
    }

    // ========== Slippage & Output Errors ==========

    function test_DeleverageRepay_RevertsSlippageExceeded_MinOutput() public {
        _setupPosition(10 ether, 4 ether);
        // flash 3 -> 3 MYT -> repay 2 -> surplus 1 MYT -> withdraw 5 -> total 6 MYT -> 6 underlying -> repay 3 -> surplus 3
        // Set minOutput=4 -> 3 < 4 -> revert
        vm.expectRevert(V3Leverager.SlippageExceeded.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(_buildParams(3 ether, 5 ether, 2 ether, 4 ether));
    }

    function test_DeleverageRepay_RevertsInsufficientOutput() public {
        _setupPosition(10 ether, 8 ether);
        // flash 6 -> 6 MYT -> repay 5 -> surplus 1 MYT -> withdraw 1 -> total 2 MYT -> 2 underlying -> 2 < 6 -> revert
        vm.expectRevert(V3Leverager.InsufficientOutput.selector);
        vm.prank(address(vault));
        leverager.deleverageRepay(_buildParams(6 ether, 1 ether, 5 ether, 0));
    }
}

// ============================================================================
// Vault Deleverage Integration Tests (withdrawal path 3)
// ============================================================================

contract VaultDeleverageIntegrationTest is LogrisTestBase {

    /// @dev ERC-7201 storage slot for LeveragedVault.vaultPositionId
    bytes32 constant VAULT_POSITION_ID_SLOT =
        bytes32(uint256(0x66ffcd6e30a6e809fc5f771c6fbd297089c8842af4bafa5c4f2a8100b3cc4600) + 8);

    function setUp() public {
        _deployLogrisStack();
    }

    /// @dev Sets up a vault position with exact collateral and debt amounts.
    ///      Same approach as V3LeveragerDeleverageTest._setupPosition.
    function _setupPosition(uint256 depositAmount, uint256 debtAmount) internal returns (uint256 posId) {
        // 1. Give alice vault shares
        _depositFor(alice, depositAmount);

        // 2. Create MYT (without allocating to strategy)
        underlying.mint(address(this), depositAmount);
        IERC20(address(underlying)).approve(address(mytVault), depositAmount);
        uint256 mytShares = mytVault.deposit(depositAmount, address(this));

        // 3. Transfer to vault, deposit to alchemist
        IERC20(address(mytVault)).transfer(address(vault), mytShares);

        vm.startPrank(address(vault));
        IERC20(address(mytVault)).approve(address(alchemist), mytShares);
        alchemist.deposit(mytShares, address(vault), 0);
        vm.stopPrank();

        posId = positionNFT.tokenOfOwnerByIndex(address(vault), 0);

        // 4. Store position ID in vault
        vm.store(address(vault), VAULT_POSITION_ID_SLOT, bytes32(posId));

        // 5. Drain vault pool balance
        vm.prank(address(vault));
        underlying.transfer(address(0xDEAD), depositAmount);

        // 6. Mint debt
        if (debtAmount > 0) {
            vm.prank(address(vault));
            alchemist.mint(posId, debtAmount, address(this));
            vm.roll(block.number + 1); // avoid CannotRepayOnMintBlock
        }
    }

    function test_WithdrawUnderlying_Path3_Deleverage() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        // With 10 MYT collateral and 4 debt:
        //   redeemableBalance = 10 - 4 = 6 ether
        //   freeWithdrawCapacity = 10 - 4*1.111 ~= 5.556 ether
        // convertToAssets(shares) = 6 ether. Since 6 > 5.556, full withdrawal triggers path 3.
        uint256 withdrawShares = shares;

        // Use the vault's own parameter calculator
        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(withdrawShares, 100, 200);

        assertTrue(repayAmount > 0, "should be path 3");

        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        vault.withdrawUnderlying(withdrawShares, flashLoanAmount, repayAmount, minUnderlyingOut, 0);

        assertTrue(IERC20(address(underlying)).balanceOf(alice) > aliceBalBefore, "alice received underlying");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    function test_WithdrawUnderlyingAtomic_WithDebt() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        // Full withdrawal triggers path 3 (deleverage) through the atomic variant
        uint256 withdrawShares = shares;

        uint256 aliceBalBefore = IERC20(address(underlying)).balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(withdrawShares, 100, 200, 0);

        assertGt(withdrawn, 0, "non-zero withdrawal");
        assertGt(IERC20(address(underlying)).balanceOf(alice), aliceBalBefore, "alice received underlying");
        assertEq(vault.balanceOf(alice), 0, "all shares burned");
    }

    function test_GetWithdrawParams_Path1_PoolSufficient() public {
        // Deposit only (no leverage) - pool retains all funds
        _depositFor(alice, 10 ether);

        uint256 shares = vault.balanceOf(alice);
        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        assertEq(flashLoanAmount, 0, "path 1: no flash loan");
        assertEq(repayAmount, 0, "path 1: no repay");
        assertEq(minUnderlyingOut, 10 ether, "path 1: exact amount");
    }

    function test_GetWithdrawParams_Path2_FreeCapacity() public {
        // Leverage with no debt -> freeWithdrawCapacity = full collateral
        _setupPosition(10 ether, 0);
        assertEq(vault.getDepositPoolBalance(), 0);

        uint256 shares = vault.balanceOf(alice) / 4;
        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        assertEq(flashLoanAmount, 0, "path 2: no flash loan");
        assertEq(repayAmount, 0, "path 2: no repay");
        assertGt(minUnderlyingOut, 0, "path 2: slippage-adjusted output");
    }

    function test_VaultDeleveraged_EmitsEvent() public {
        _setupPosition(10 ether, 4 ether);
        uint256 shares = vault.balanceOf(alice);
        // Full withdrawal triggers path 3 (deleverage) which emits VaultDeleveraged

        (uint256 flashLoanAmount, uint256 repayAmount, uint256 minUnderlyingOut) =
            vault.getWithdrawUnderlyingParameters(shares, 100, 200);

        vm.expectEmit(false, false, false, true);
        emit LeveragedVault.VaultDeleveraged(shares, repayAmount);

        vm.prank(alice);
        vault.withdrawUnderlying(shares, flashLoanAmount, repayAmount, minUnderlyingOut, 0);
    }
}
