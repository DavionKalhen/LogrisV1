// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/SimpleDebtTokenAdapter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Mock token for testing
contract MockDebtToken is ERC20 {
    constructor() ERC20("Debt Token", "DEBT") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SimpleDebtTokenAdapterTest is Test {
    SimpleDebtTokenAdapter public adapter;
    MockDebtToken public debtToken;

    address public owner = address(this);
    address public user1 = address(0x100);
    address public user2 = address(0x200);

    address public yieldToken = address(0x300);
    address public underlyingToken = address(0x400);

    uint256 public constant MIN_COLLATERALIZATION = 1.5e18;

    function setUp() public {
        debtToken = new MockDebtToken();
        adapter = new SimpleDebtTokenAdapter(address(debtToken), MIN_COLLATERALIZATION);

        // Set up yield token parameters
        adapter.addYieldToken(yieldToken, 0, 1000000 ether, 0, 0);

        // Set conversion rate
        adapter.setConversionRate(yieldToken, address(0), 1e18);
    }

    // ===== CONSTRUCTOR TESTS =====

    function testConstructor() public {
        uint256 minCollat = adapter.minimumCollateralization();
        assertEq(minCollat, MIN_COLLATERALIZATION, "Minimum collateralization should be set");
    }

    // ===== YIELD TOKEN CONFIGURATION TESTS =====

    function testAddYieldToken() public {
        address newYieldToken = address(0x500);

        adapter.addYieldToken(newYieldToken, 100 ether, 1000 ether, 5 ether, 1e16);

        (uint256 expectedValue, uint256 maxExpectedValue, uint256 maxLoss, uint256 creditUnlockRate) =
            adapter.getYieldTokenParameters(newYieldToken);

        assertEq(expectedValue, 100 ether, "Expected value should be set");
        assertEq(maxExpectedValue, 1000 ether, "Max expected value should be set");
        assertEq(maxLoss, 5 ether, "Max loss should be set");
        assertEq(creditUnlockRate, 1e16, "Credit unlock rate should be set");
    }

    function testOnlyOwnerCanAddYieldToken() public {
        vm.prank(user1);
        vm.expectRevert();
        adapter.addYieldToken(address(0x600), 0, 1000 ether, 0, 0);
    }

    // ===== CONVERSION RATE TESTS =====

    function testSetConversionRate() public {
        address newYield = address(0x700);
        address newUnderlying = address(0x800);

        adapter.setConversionRate(newYield, newUnderlying, 2e18);

        // The conversion rate is set internally, we can verify by checking the deposit function behavior
        // In this simple implementation, the rate isn't directly queryable
    }

    function testOnlyOwnerCanSetConversionRate() public {
        vm.prank(user1);
        vm.expectRevert();
        adapter.setConversionRate(yieldToken, underlyingToken, 2e18);
    }

    // ===== POSITION TESTS =====

    function testPositionsInitiallyZero() public {
        (uint256 shares, uint256 lastAccruedWeight) = adapter.positions(user1, yieldToken);

        assertEq(shares, 0, "Initial shares should be 0");
        assertEq(lastAccruedWeight, 0, "Initial accrued weight should be 0");
    }

    // ===== ACCOUNTS TESTS =====

    function testAccountsInitiallyZero() public {
        (int256 debt, uint256 lastUpdate) = adapter.accounts(user1);

        assertEq(debt, 0, "Initial debt should be 0");
        assertEq(lastUpdate, 0, "Initial last update should be 0");
    }

    // ===== CONVERSION TESTS =====

    function testConvertSharesToUnderlyingTokens() public {
        uint256 shares = 100 ether;
        uint256 underlying = adapter.convertSharesToUnderlyingTokens(yieldToken, shares);

        assertEq(underlying, shares, "1:1 conversion in simple adapter");
    }

    function testConvertUnderlyingTokensToShares() public {
        uint256 amount = 100 ether;
        uint256 shares = adapter.convertUnderlyingTokensToShares(yieldToken, amount);

        assertEq(shares, amount, "1:1 conversion in simple adapter");
    }

    function testNormalizeDebtTokensToUnderlying() public {
        uint256 debtAmount = 100 ether;
        uint256 underlying = adapter.normalizeDebtTokensToUnderlying(underlyingToken, debtAmount);

        assertEq(underlying, debtAmount, "1:1 conversion in simple adapter");
    }

    function testConvertUnderlyingTokensToYield() public {
        uint256 amount = 100 ether;
        uint256 yieldAmount = adapter.convertUnderlyingTokensToYield(yieldToken, amount);

        assertEq(yieldAmount, amount, "1:1 conversion in simple adapter");
    }

    function testConvertYieldTokensToUnderlying() public {
        uint256 yieldAmount = 100 ether;
        uint256 underlying = adapter.convertYieldTokensToUnderlying(yieldToken, yieldAmount);

        assertEq(underlying, yieldAmount, "1:1 conversion in simple adapter");
    }

    // ===== MINT TESTS =====

    function testMint() public {
        uint256 mintAmount = 50 ether;

        adapter.mint(mintAmount, user1);

        (int256 debt,) = adapter.accounts(user1);
        assertEq(debt, int256(mintAmount), "Debt should increase by mint amount");
    }

    function testMintUpdatesLastUpdate() public {
        adapter.mint(50 ether, user1);

        (, uint256 lastUpdate) = adapter.accounts(user1);
        assertEq(lastUpdate, block.timestamp, "Last update should be current timestamp");
    }

    function testMintFrom() public {
        // First approve
        vm.prank(user1);
        adapter.approveMint(address(this), 100 ether);

        // Then mint from user1
        adapter.mintFrom(user1, 50 ether, user2);

        (int256 debt,) = adapter.accounts(user1);
        assertEq(debt, 50 ether, "User1 debt should increase");
    }

    function testMintFromWithoutApprovalFails() public {
        vm.expectRevert("Not approved to mint");
        adapter.mintFrom(user1, 50 ether, user2);
    }

    function testMintFromExceedsApprovalFails() public {
        vm.prank(user1);
        adapter.approveMint(address(this), 10 ether);

        vm.expectRevert("Not approved to mint");
        adapter.mintFrom(user1, 50 ether, user2);
    }

    // ===== BURN TESTS =====

    function testBurn() public {
        // First mint some debt
        adapter.mint(100 ether, user1);

        // Then burn some
        adapter.burn(30 ether, user1);

        (int256 debt,) = adapter.accounts(user1);
        assertEq(debt, 70 ether, "Debt should decrease by burn amount");
    }

    function testBurnReducesDebtBelowZero() public {
        // Burn without prior mint results in negative debt (credit)
        adapter.burn(50 ether, user1);

        (int256 debt,) = adapter.accounts(user1);
        assertEq(debt, -50 ether, "Debt should be negative (credit)");
    }

    // ===== DEPOSIT TESTS =====

    function testDepositUnderlying() public {
        uint256 depositAmount = 100 ether;

        uint256 shares = adapter.depositUnderlying(yieldToken, depositAmount, user1, 90 ether);

        assertEq(shares, depositAmount, "Shares should equal deposit amount");

        (uint256 userShares,) = adapter.positions(user1, yieldToken);
        assertEq(userShares, depositAmount, "User shares should be credited");
    }

    function testDepositUnderlyingUpdatesExpectedValue() public {
        (uint256 expectedBefore,,,) = adapter.getYieldTokenParameters(yieldToken);

        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        (uint256 expectedAfter,,,) = adapter.getYieldTokenParameters(yieldToken);
        assertEq(expectedAfter, expectedBefore + 100 ether, "Expected value should increase");
    }

    function testDepositUnderlyingMinimumAmountCheck() public {
        vm.expectRevert("Amount less than minimum");
        adapter.depositUnderlying(yieldToken, 50 ether, user1, 100 ether);
    }

    // ===== WITHDRAW TESTS =====

    function testWithdrawUnderlyingFrom() public {
        // First deposit
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        // Then withdraw
        vm.prank(user1);
        uint256 amount = adapter.withdrawUnderlyingFrom(user1, yieldToken, 50 ether, user2, 45 ether);

        assertEq(amount, 50 ether, "Withdrawn amount should match shares");

        (uint256 remainingShares,) = adapter.positions(user1, yieldToken);
        assertEq(remainingShares, 50 ether, "Remaining shares should be correct");
    }

    function testWithdrawUnderlyingFromRequiresApproval() public {
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        // Try to withdraw as user2 without approval
        vm.prank(user2);
        vm.expectRevert("Not approved to withdraw");
        adapter.withdrawUnderlyingFrom(user1, yieldToken, 50 ether, user2, 45 ether);
    }

    function testWithdrawUnderlyingFromWithApproval() public {
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        // Approve user2
        vm.prank(user1);
        adapter.approveWithdraw(user2, yieldToken, 50 ether);

        // Withdraw as user2
        vm.prank(user2);
        uint256 amount = adapter.withdrawUnderlyingFrom(user1, yieldToken, 50 ether, user2, 45 ether);

        assertEq(amount, 50 ether, "Should withdraw approved amount");
    }

    function testWithdrawExceedsSharesFails() public {
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        vm.prank(user1);
        vm.expectRevert("Not enough shares");
        adapter.withdrawUnderlyingFrom(user1, yieldToken, 150 ether, user1, 0);
    }

    // ===== APPROVAL TESTS =====

    function testApproveMint() public {
        vm.prank(user1);
        adapter.approveMint(user2, 100 ether);

        // Verify by attempting to mint
        vm.prank(user2);
        adapter.mintFrom(user1, 50 ether, user2);

        (int256 debt,) = adapter.accounts(user1);
        assertEq(debt, 50 ether, "Mint should succeed with approval");
    }

    function testApproveWithdraw() public {
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);

        vm.prank(user1);
        adapter.approveWithdraw(user2, yieldToken, 100 ether);

        // Verify by attempting to withdraw
        vm.prank(user2);
        adapter.withdrawUnderlyingFrom(user1, yieldToken, 50 ether, user2, 0);

        (uint256 remainingShares,) = adapter.positions(user1, yieldToken);
        assertEq(remainingShares, 50 ether, "Withdraw should succeed with approval");
    }

    // ===== COLLATERALIZATION TESTS =====

    function testMinimumCollateralization() public {
        uint256 minCollat = adapter.minimumCollateralization();
        assertEq(minCollat, MIN_COLLATERALIZATION, "Should return correct minimum collateralization");
    }

    // ===== YIELD TOKEN PARAMETERS TESTS =====

    function testGetYieldTokenParameters() public {
        adapter.addYieldToken(address(0x999), 100 ether, 500 ether, 10 ether, 1e15);

        (uint256 expected, uint256 maxExpected, uint256 maxLoss, uint256 unlockRate) =
            adapter.getYieldTokenParameters(address(0x999));

        assertEq(expected, 100 ether, "Expected value should match");
        assertEq(maxExpected, 500 ether, "Max expected value should match");
        assertEq(maxLoss, 10 ether, "Max loss should match");
        assertEq(unlockRate, 1e15, "Unlock rate should match");
    }

    function testGetYieldTokenParametersUninitialized() public {
        (uint256 expected, uint256 maxExpected, uint256 maxLoss, uint256 unlockRate) =
            adapter.getYieldTokenParameters(address(0x888));

        assertEq(expected, 0, "Uninitialized expected should be 0");
        assertEq(maxExpected, 0, "Uninitialized max expected should be 0");
        assertEq(maxLoss, 0, "Uninitialized max loss should be 0");
        assertEq(unlockRate, 0, "Uninitialized unlock rate should be 0");
    }

    // ===== MULTIPLE OPERATIONS TESTS =====

    function testMultipleDepositsAndWithdraws() public {
        // Multiple deposits
        adapter.depositUnderlying(yieldToken, 100 ether, user1, 90 ether);
        adapter.depositUnderlying(yieldToken, 50 ether, user1, 45 ether);
        adapter.depositUnderlying(yieldToken, 25 ether, user1, 20 ether);

        (uint256 totalShares,) = adapter.positions(user1, yieldToken);
        assertEq(totalShares, 175 ether, "Total shares should be sum of deposits");

        // Partial withdraw
        vm.prank(user1);
        adapter.withdrawUnderlyingFrom(user1, yieldToken, 50 ether, user1, 0);

        (uint256 remainingShares,) = adapter.positions(user1, yieldToken);
        assertEq(remainingShares, 125 ether, "Remaining shares should be correct");
    }

    function testMultipleMintAndBurn() public {
        adapter.mint(100 ether, user1);
        adapter.mint(50 ether, user1);
        adapter.burn(30 ether, user1);
        adapter.mint(20 ether, user1);
        adapter.burn(40 ether, user1);

        (int256 debt,) = adapter.accounts(user1);
        // 100 + 50 - 30 + 20 - 40 = 100
        assertEq(debt, 100 ether, "Final debt should be correct");
    }
}
