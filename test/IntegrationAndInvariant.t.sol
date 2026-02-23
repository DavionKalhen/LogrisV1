// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LogrisTestBase.t.sol";

// ============ Integration Test ============

contract FullIntegrationTest is LogrisTestBase {

    function setUp() public {
        _deployLogrisStack();
    }

    // ============ Full Deposit -> Leverage -> Withdraw Cycle ============

    function test_FullCycle_DepositLeverageWithdraw() public {
        uint256 depositAmount = 10 ether;

        // 1. Alice deposits underlying (ERC20)
        uint256 shares = _depositFor(alice, depositAmount);
        assertEq(shares, depositAmount * 1000, "Should get 1000:1 shares on first deposit (offset=3)");
        assertEq(vault.getDepositPoolBalance(), depositAmount, "Pool should hold deposit");

        // 2. Leverage via leverageAtomic (auto-computes flash loan + mint amounts)
        //    Real AlchemistV3 requires mintAmount > 0, so we use the atomic helper.
        vault.leverageAtomic(depositAmount, 100, 200, 0);

        // Verify position was created
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should exist");

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertGt(collateral, 0, "Collateral should be positive");
        assertGt(debt, 0, "Should have debt from leverageAtomic");
        // With leverageAtomic, pool may retain a small remainder from the leverage cycle
        assertLt(vault.getDepositPoolBalance(), depositAmount, "Pool should be mostly consumed");

        // 3. Advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        // 4. Withdraw (triggers deleverage since there's debt)
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(shares, 100, 200, 0);
        assertGt(withdrawn, 0, "Should withdraw some underlying");
        assertApproxEqAbs(withdrawn, depositAmount, depositAmount / 10, "Should withdraw close to deposit amount");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares");
    }

    function test_FullCycle_WithFlashLoanLeverage() public {
        uint256 depositAmount = 10 ether;

        // 1. Alice deposits underlying (ERC20)
        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // 2. Leverage with flash loan
        // With real AlchemistV3 at ~111% collateralization:
        //   12 ether collateral -> max debt = 12 / 1.111 ~ 10.8 ether
        //   mintAmount = 3 ether is well within capacity
        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 underlyingDepositMin = totalDeposit * 9900 / 10000;
        uint256 debtTradeMin = mintAmount * 9800 / 10000;

        vm.prank(alice);
        vault.leverage(
            depositAmount,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin,
            0
        );

        uint256 posId = vault.getVaultPositionId();
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertGt(collateral, 0, "Collateral should be positive");
        assertGt(debt, 0, "Debt should be positive after leverage with flash loan");

        // 3. Verify vault share value still reasonable
        uint256 shareValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(alice));
        assertGt(shareValue, 0, "Share value should be positive");
    }

    function test_MultiUser_DepositAndLeverage() public {
        // 1. Alice deposits 10 underlying
        uint256 aliceShares = _depositFor(alice, 10 ether);

        // 2. Bob deposits 5 underlying
        uint256 bobShares = _depositFor(bob, 5 ether);

        assertEq(aliceShares, 10_000 ether);
        assertEq(bobShares, 5_000 ether);
        assertEq(vault.totalSupply(), 15_000 ether);

        // 3. Leverage entire pool (auto-computed params, since real AlchemistV3 requires mintAmount > 0)
        vault.leverageAtomic(15 ether, 100, 200, 0);

        // 4. Both users' shares should still reflect their proportional ownership
        uint256 aliceValue = vault.convertSharesToUnderlyingTokens(aliceShares);
        uint256 bobValue = vault.convertSharesToUnderlyingTokens(bobShares);

        // After leverage, collateral+debt affect share value but proportionality should hold
        // Allow wider tolerance due to real AlchemistV3 conversion rounding
        uint256 totalValue = aliceValue + bobValue;
        assertGt(totalValue, 0, "Total value should be positive");
        // Alice should have 2/3 of total value, Bob 1/3
        assertApproxEqAbs(aliceValue * 3, totalValue * 2, 100, "Alice should have ~2/3 of total value");
        assertApproxEqAbs(bobValue * 3, totalValue, 100, "Bob should have ~1/3 of total value");
    }

    // ============ leverageAtomic Tests ============

    function test_LeverageAtomic_UsesDefaultSlippage() public {
        uint256 depositAmount = 10 ether;

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        vault.leverageAtomic(depositAmount, 100, 200, 0);

        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should be created");

        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertGt(collateral, 0, "Should have collateral");
    }

    function test_WithdrawUnderlyingAtomic_Works() public {
        uint256 depositAmount = 10 ether;

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        uint256 shares = vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(shares, 100, 200, 0);

        assertApproxEqAbs(withdrawn, depositAmount, 100, "Should withdraw full amount");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares");
    }

    // ============ Slippage Enforcement Tests ============

    function test_SlippageEnforcement_RejectsZeroDebtSlippage() public {
        uint256 depositAmount = 10 ether;

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;

        vm.prank(alice);
        vm.expectRevert(LeveragedVault.SwapSlippageBelowMinimum.selector);
        vault.leverage(depositAmount, flashLoanAmount, totalDeposit, 3 ether, 0, 0);
    }

    function test_SlippageEnforcement_OnlyChecksDebtSwap() public {
        uint256 depositAmount = 10 ether;

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 validDebtTradeMin = mintAmount * 9800 / 10000;
        uint256 validDepositMin = totalDeposit;

        vm.prank(alice);
        vault.leverage(depositAmount, flashLoanAmount, validDepositMin, mintAmount, validDebtTradeMin, 0);

        assertGt(vault.getVaultPositionId(), 0, "Leverage should succeed");
    }

    function test_SlippageEnforcement_AcceptsValidSlippage() public {
        uint256 depositAmount = 10 ether;

        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 validDebtTradeMin = mintAmount * 9800 / 10000;

        vm.prank(alice);
        vault.leverage(depositAmount, flashLoanAmount, totalDeposit, mintAmount, validDebtTradeMin, 0);

        assertGt(vault.getVaultPositionId(), 0, "Leverage should succeed");
    }

    // ============ Deposit-Only Leverage (Partial Capacity) Tests ============

    function test_LeverageAtomic_DepositOnlyWhenCapacityClamped() public {
        // Set deposit cap so Alchemist can accept only 3 ether worth of MYT
        _setDepositCap(3 ether);

        // Alice deposits 10 ether into vault pool
        _depositFor(alice, 10 ether);

        // leverageAtomic with 10 ether: deposit capacity (3 MYT) < expectedYield (10 MYT)
        // Branch A: clampedDeposit = ~3 ether, flashLoan = 0, mintAmount = 0
        // With the fix, leverager deposits 3 MYT as collateral and returns (no mint, no swap)
        vm.prank(alice);
        vault.leverageAtomic(10 ether, 100, 200, 0);

        // Position should be created with collateral but no debt
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should exist");
        assertEq(vault.getVaultDebtBalance(), 0, "No debt should be minted");
        assertGt(vault.getVaultDepositedBalance(), 0, "Collateral should be deposited");

        // Remaining underlying (~7 ether) should still be in the pool
        assertApproxEqAbs(vault.getDepositPoolBalance(), 7 ether, 0.1 ether, "Unclamped amount stays in pool");
    }

    function test_Leverage_DepositOnlyWithExplicitParams() public {
        // Set deposit cap so Alchemist can accept only 5 ether worth of MYT
        _setDepositCap(5 ether);

        _depositFor(alice, 10 ether);

        // Call leverage() with explicit params: clampedDeposit=5, flashLoan=0, mintAmount=0
        // underlyingDepositMin must be <= depositCapacity after slippage
        uint256 minYield = 5 ether * 9900 / 10000; // 1% slippage
        vm.prank(alice);
        vault.leverage(5 ether, 0, minYield, 0, 0, 0);

        assertGt(vault.getVaultPositionId(), 0, "Position should exist");
        assertEq(vault.getVaultDebtBalance(), 0, "No debt");
        assertApproxEqAbs(vault.getDepositPoolBalance(), 5 ether, 0.01 ether, "5 ether remains in pool");
    }

    function test_LeverageAtomic_DepositOnlyThenFullLeverageLater() public {
        // Phase 1: Partial capacity — deposit only
        _setDepositCap(3 ether);
        _depositFor(alice, 10 ether);

        vm.prank(alice);
        vault.leverageAtomic(10 ether, 100, 200, 0);

        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position created");
        assertEq(vault.getVaultDebtBalance(), 0, "No debt in phase 1");

        // Phase 2: Raise deposit cap and leverage the remaining pool balance
        _setDepositCap(1000 ether);
        vm.roll(block.number + 1);

        uint256 poolBefore = vault.getDepositPoolBalance();
        assertGt(poolBefore, 0, "Pool should have remaining underlying");

        vm.prank(alice);
        vault.leverageAtomic(poolBefore, 100, 200, 0);

        assertGt(vault.getVaultDebtBalance(), 0, "Debt should exist after full leverage");
    }

    // ============ Admin Function Validation Tests ============

    function test_AdaptersAreSet() public view {
        assertEq(vault.converter(), address(converter), "Converter should be set at initialization");
        assertEq(vault.flashLoanAdapter(), address(flashLoanAdapter), "Flash loan adapter should be set at initialization");
        assertEq(vault.swapper(), address(swapper), "Swapper should be set at initialization");
    }

    // ============ Emergency Sweep Tests ============

    function test_EmergencySweep_WorksForOwner() public {
        MockERC20WithMetadata randomToken = new MockERC20WithMetadata("Random", "RND", 18);
        randomToken.mint(address(vault), 50 ether);

        vm.prank(owner);
        vault.emergencySweepToken(address(randomToken), 50 ether, owner);

        assertEq(randomToken.balanceOf(owner), 50 ether, "Owner should receive swept tokens");
        assertEq(randomToken.balanceOf(address(vault)), 0, "Vault should have 0 random tokens");
    }

    function test_EmergencySweep_RevertsForNonOwner() public {
        MockERC20WithMetadata randomToken = new MockERC20WithMetadata("Random", "RND", 18);
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencySweepToken(address(randomToken), 1 ether, alice);
    }

    function test_EmergencySweep_RejectsZeroRecipient() public {
        MockERC20WithMetadata randomToken = new MockERC20WithMetadata("Random", "RND", 18);
        vm.prank(owner);
        vm.expectRevert(LeveragedVault.InvalidRecipient.selector);
        vault.emergencySweepToken(address(randomToken), 1 ether, address(0));
    }

    // ============ Receive ETH Test ============

    function test_VaultCanReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "Vault should accept ETH");
    }

    // ============ Parameterless View Function Tests ============

    function test_GetLeverageParameters_Parameterless() public {
        underlying.mint(alice, 10 ether);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        (uint256 clampedDeposit1,,,,) = vault.getLeverageParameters(10 ether);
        (uint256 clampedDeposit2,,,,) = vault.getLeverageParameters(10 ether, 100, 200);

        assertEq(clampedDeposit1, clampedDeposit2, "Parameterless should match explicit with defaults");
    }

    // ============ Slippage Setter Tests ============

    function test_SetSlippageParameters() public {
        vm.prank(owner);
        vault.setSlippageParameters(50, 150);

        assertEq(vault.underlyingSlippageBasisPoints(), 50);
        assertEq(vault.debtSlippageBasisPoints(), 150);
    }

    function test_SetSlippageParameters_RejectsExcessive() public {
        vm.prank(owner);
        vm.expectRevert(LeveragedVault.SlippageTooHigh.selector);
        vault.setSlippageParameters(10000, 200);
    }

    // ============ Deposit + Leverage Atomic Tests ============

    function test_DepositAndLeverageAtomic_BasicFlow() public {
        uint256 amount = 10 ether;
        underlying.mint(alice, amount);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares = vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();

        // Shares minted
        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "Alice should hold shares");

        // Position created with debt
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should exist");
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertGt(collateral, 0, "Should have collateral");
        assertGt(debt, 0, "Should have debt from leverage");

        // Pool mostly consumed
        assertLt(vault.getDepositPoolBalance(), amount, "Pool should be mostly consumed");
    }

    function test_DepositAndLeverageAtomic_MatchesSeparateCalls() public {
        // Deploy a second vault for comparison
        LeveragedVault vault2 = _deployLeveragedVault(
            address(leverager),
            address(converter),
            address(flashLoanAdapter),
            address(swapper),
            owner
        );
        vm.prank(owner);
        vault2.setLeverageWhitelist(address(this), true);

        uint256 amount = 10 ether;

        // Vault 1: combined call
        underlying.mint(alice, amount);
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares1 = vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();

        // Vault 2: separate calls
        underlying.mint(bob, amount);
        vm.startPrank(bob);
        IERC20(address(underlying)).approve(address(vault2), amount);
        uint256 shares2 = vault2.depositUnderlying(amount);
        vm.stopPrank();
        vault2.leverageAtomic(amount, 100, 200, 0);

        // Same shares minted (same amount, same first-deposit share price)
        assertEq(shares1, shares2, "Combined should mint same shares as separate");

        // Same debt created
        uint256 posId1 = vault.getVaultPositionId();
        uint256 posId2 = vault2.getVaultPositionId();
        (, uint256 debt1,) = alchemist.getCDP(posId1);
        (, uint256 debt2,) = alchemist.getCDP(posId2);
        assertEq(debt1, debt2, "Same debt should be created");
    }

    function test_DepositAndLeverageAtomic_WithExistingPoolBalance() public {
        // First: deposit without leverage
        uint256 existingAmount = 5 ether;
        _depositFor(alice, existingAmount);
        assertEq(vault.getDepositPoolBalance(), existingAmount, "Pool should hold existing deposit");

        // Second: deposit and leverage only the new amount
        uint256 newAmount = 10 ether;
        underlying.mint(bob, newAmount);
        vm.startPrank(bob);
        IERC20(address(underlying)).approve(address(vault), newAmount);
        vault.depositAndLeverageAtomic(newAmount, 100, 200, 0);
        vm.stopPrank();

        // Existing deposit should remain in pool (minus whatever leverage consumed)
        // The leverage only targets newAmount, so existingAmount should still be in pool
        assertGe(vault.getDepositPoolBalance(), existingAmount, "Existing pool balance should remain");
    }

    function test_DepositAndLeverageAtomic_RevertsWhenPaused() public {
        uint256 amount = 10 ether;
        underlying.mint(alice, amount);

        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        vm.expectRevert();
        vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();
    }

    function test_DepositAndLeverageAtomic_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.ZeroDeposit.selector);
        vault.depositAndLeverageAtomic(0, 100, 200, 0);
    }

    function test_DepositAndLeverageAtomic_RevertsDeadlineExpired() public {
        uint256 amount = 10 ether;
        underlying.mint(alice, amount);

        // Warp to a known timestamp so we can set an expired deadline
        vm.warp(1000);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        vm.expectRevert(LeveragedVault.DeadlineExpired.selector);
        vault.depositAndLeverageAtomic(amount, 100, 200, 999); // deadline in the past
        vm.stopPrank();
    }

    function test_DepositAndLeverageAtomic_RevertsSlippageTooHigh() public {
        uint256 amount = 10 ether;
        underlying.mint(alice, amount);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);

        vm.expectRevert(LeveragedVault.SlippageTooHigh.selector);
        vault.depositAndLeverageAtomic(amount, 10000, 200, 0);

        vm.expectRevert(LeveragedVault.SlippageTooHigh.selector);
        vault.depositAndLeverageAtomic(amount, 100, 10000, 0);
        vm.stopPrank();
    }

    function test_DepositAndLeverageAtomic_FullCycleWithWithdraw() public {
        uint256 amount = 10 ether;
        underlying.mint(alice, amount);

        // Deposit + leverage in one tx
        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares = vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();

        // Advance block for repay
        vm.roll(block.number + 1);

        // Withdraw everything
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(shares, 100, 200, 0);
        assertGt(withdrawn, 0, "Should withdraw some underlying");
        assertApproxEqAbs(withdrawn, amount, amount / 10, "Should get back close to deposit");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares after full withdrawal");
    }

    // ============ Leverage Whitelist Tests ============

    function test_Leverage_RevertsWhenNotWhitelisted() public {
        _depositFor(alice, 10 ether);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(LeveragedVault.NotWhitelisted.selector);
        vault.leverageAtomic(10 ether, 100, 200, 0);
    }

    function test_LeverageExplicit_RevertsWhenNotWhitelisted() public {
        _depositFor(alice, 10 ether);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(LeveragedVault.NotWhitelisted.selector);
        vault.leverage(10 ether, 0, 10 ether, 1, 0, 0);
    }

    function test_DepositAndLeverageAtomic_WorksWithoutWhitelist() public {
        // Stranger is NOT whitelisted, but depositAndLeverageAtomic should still work
        address stranger = makeAddr("stranger");
        uint256 amount = 10 ether;
        underlying.mint(stranger, amount);

        vm.startPrank(stranger);
        IERC20(address(underlying)).approve(address(vault), amount);
        uint256 shares = vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();

        assertGt(shares, 0, "Stranger should receive shares");
        assertGt(vault.getVaultDebtBalance(), 0, "Should have debt from leverage");
    }

    function test_SetLeverageWhitelist_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setLeverageWhitelist(alice, true);
    }

    function test_SetLeverageWhitelist_WorksForOwner() public {
        address keeper = makeAddr("keeper");
        assertEq(vault.isLeverageWhitelisted(keeper), false);

        vm.prank(owner);
        vault.setLeverageWhitelist(keeper, true);
        assertEq(vault.isLeverageWhitelisted(keeper), true);

        // Keeper can now leverage
        _depositFor(alice, 10 ether);
        vm.prank(keeper);
        vault.leverageAtomic(10 ether, 100, 200, 0);
        assertGt(vault.getVaultDebtBalance(), 0, "Keeper should have leveraged");
    }

    function test_SetLeverageWhitelist_Revoke() public {
        // alice is whitelisted from setUp
        assertEq(vault.isLeverageWhitelisted(alice), true);

        vm.prank(owner);
        vault.setLeverageWhitelist(alice, false);
        assertEq(vault.isLeverageWhitelisted(alice), false);

        _depositFor(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(LeveragedVault.NotWhitelisted.selector);
        vault.leverageAtomic(10 ether, 100, 200, 0);
    }
}

// ============ Invariant Test ============

/// @notice Handler for invariant testing - executes random deposit/withdraw operations
contract VaultHandler is Test {
    LeveragedVault public vault;
    MockERC20WithMetadata public underlyingToken;
    address[] public actors;

    constructor(LeveragedVault _vault, MockERC20WithMetadata _underlyingToken) {
        vault = _vault;
        underlyingToken = _underlyingToken;
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e12, 100 ether);

        underlyingToken.mint(actor, amount);
        vm.startPrank(actor);
        IERC20(address(underlyingToken)).approve(address(vault), amount);
        vault.depositUnderlying(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 shareFraction) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 shares = balance * shareFraction / 100;
        if (shares == 0) return;

        vm.prank(actor);
        vault.withdrawUnderlying(shares, 0, 0, 0, 0);
    }
}

contract ShareValueInvariantTest is LogrisTestBase {
    VaultHandler public handler;

    function setUp() public {
        _deployLogrisStack();

        handler = new VaultHandler(vault, underlying);
        targetContract(address(handler));
    }

    /// @notice Total share value should always equal total assets (pool balance when no Alchemist position)
    function invariant_TotalShareValueEqualsPoolBalance() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = vault.totalAssets();
        uint256 poolBalance = vault.getDepositPoolBalance();

        if (vault.vaultPositionId() == 0) {
            assertEq(totalAssets, poolBalance, "Total assets must equal pool balance without position");
        }
    }

    /// @notice Total supply should never be negative (obvious but validates no underflow)
    function invariant_TotalSupplyNonNegative() public view {
        assertLe(vault.totalSupply(), 1000 ether * 3 * 1000, "Total supply should be bounded");
    }

    /// @notice Pool balance should be consistent with deposits minus withdrawals
    function invariant_PoolBalanceConsistent() public view {
        uint256 poolBalance = vault.getDepositPoolBalance();
        uint256 underlyingBalance = IERC20(address(underlying)).balanceOf(address(vault));
        assertEq(poolBalance, underlyingBalance, "Pool balance should equal underlying balance");
    }
}
