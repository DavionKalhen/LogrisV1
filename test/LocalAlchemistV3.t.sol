// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LocalAlchemistV3Base.t.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title LocalAlchemistV3Test
/// @notice Tests that verify our contracts work with the real AlchemistV3 stack
///         deployed locally (no fork needed).
contract LocalAlchemistV3Test is LocalAlchemistV3Base {
    address public owner;
    address public alice;
    address public bob;

    function setUp() public {
        _deployLocalAlchemistV3();

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    // ============ AlchemistV3 Stack Verification ============

    function test_LocalStack_AllContractsDeployed() public view {
        assertTrue(address(alchemist) != address(0), "Alchemist deployed");
        assertTrue(address(positionNFT) != address(0), "Position NFT deployed");
        assertTrue(address(transmuter) != address(0), "Transmuter deployed");
        assertTrue(address(feeVault) != address(0), "Fee vault deployed");
        assertTrue(address(mytVault) != address(0), "MYT vault deployed");
        assertTrue(address(debtToken) != address(0), "Debt token deployed");
    }

    function test_LocalStack_AlchemistConfig() public view {
        assertEq(alchemist.minimumCollateralization(), MIN_COLLATERALIZATION);
        assertEq(alchemist.collateralizationLowerBound(), COLLATERALIZATION_LOWER_BOUND);
        assertEq(alchemist.alchemistPositionNFT(), address(positionNFT));
        assertEq(alchemist.debtToken(), address(debtToken));
        assertEq(alchemist.myt(), address(mytVault));
    }

    function test_LocalStack_DepositCreatesPosition() public {
        uint256 amount = 100e18;
        uint256 shares = _fundWithMYT(alice, amount);

        uint256 posId = _depositToAlchemist(alice, shares);
        assertGt(posId, 0, "Position ID should be > 0");

        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertEq(collateral, shares, "Collateral should match deposit");
    }

    function test_LocalStack_MintDebtAgainstPosition() public {
        uint256 amount = 100e18;
        uint256 shares = _fundWithMYT(alice, amount);
        uint256 posId = _depositToAlchemist(alice, shares);

        // Mint some debt (well under the limit)
        uint256 maxBorrowable = alchemist.getMaxBorrowable(posId);
        uint256 mintAmount = maxBorrowable / 2;

        vm.prank(alice);
        alchemist.mint(posId, mintAmount, alice);

        (, uint256 debt,) = alchemist.getCDP(posId);
        assertEq(debt, mintAmount, "Debt should match minted amount");
        assertEq(IERC20(address(debtToken)).balanceOf(alice), mintAmount, "Alice should hold debt tokens");
    }

    function test_LocalStack_BurnDebtReducesDebt() public {
        uint256 amount = 100e18;
        uint256 shares = _fundWithMYT(alice, amount);
        uint256 posId = _depositToAlchemist(alice, shares);

        uint256 maxBorrowable = alchemist.getMaxBorrowable(posId);
        uint256 mintAmount = maxBorrowable / 2;

        vm.startPrank(alice);
        alchemist.mint(posId, mintAmount, alice);

        // Advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        // Burn half the debt
        uint256 burnAmount = mintAmount / 2;
        IERC20(address(debtToken)).approve(address(alchemist), burnAmount);
        alchemist.burn(burnAmount, posId);
        vm.stopPrank();

        (, uint256 debtAfter,) = alchemist.getCDP(posId);
        assertEq(debtAfter, mintAmount - burnAmount, "Debt should decrease by burn amount");
    }

    function test_LocalStack_WithdrawReducesCollateral() public {
        uint256 amount = 100e18;
        uint256 shares = _fundWithMYT(alice, amount);
        uint256 posId = _depositToAlchemist(alice, shares);

        // Withdraw half (no debt, so no collateralization constraint)
        uint256 withdrawAmount = shares / 2;

        vm.prank(alice);
        alchemist.withdraw(withdrawAmount, alice, posId);

        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertEq(collateral, shares - withdrawAmount, "Collateral should decrease");
    }

    function test_LocalStack_ConversionFunctions() public view {
        // Test that conversion functions route through VaultV2 correctly
        uint256 mytAmount = 100e18;
        uint256 underlyingValue = alchemist.convertYieldTokensToUnderlying(mytAmount);
        assertGt(underlyingValue, 0, "Should convert MYT to underlying");

        uint256 backToMyt = alchemist.convertUnderlyingTokensToYield(underlyingValue);
        // Should be approximately equal (rounding allowed)
        assertApproxEqAbs(backToMyt, mytAmount, 1, "Round-trip conversion should be ~equal");
    }

    function test_LocalStack_PositionNFTOwnership() public {
        uint256 shares = _fundWithMYT(alice, 100e18);
        _depositToAlchemist(alice, shares);

        assertEq(positionNFT.balanceOf(alice), 1, "Alice should own 1 position NFT");
        uint256 tokenId = positionNFT.tokenOfOwnerByIndex(alice, 0);
        assertEq(positionNFT.ownerOf(tokenId), alice);
    }

    // ============ LeveragedVault + Real Alchemist ============

    function test_LocalStack_VaultDeployWithRealAlchemist() public {
        // Deploy mock adapters for vault
        address mockLeverager = makeAddr("leverager");
        address mockConverter = makeAddr("converter");
        address mockFlashLoan = makeAddr("flashLoan");
        address mockSwapper = makeAddr("swapper");

        LeveragedVault vault = _deployLeveragedVault(
            mockLeverager,
            mockConverter,
            mockFlashLoan,
            mockSwapper,
            owner
        );

        // Vault should be configured correctly
        assertEq(vault.getYieldToken(), address(mytVault), "Yield token should be MYT");
        assertEq(address(vault.alchemist()), address(alchemist), "Alchemist should match");
    }

    function test_LocalStack_VaultDepositYieldTokensToRealAlchemist() public {
        // Deploy vault with a mock leverager
        address mockConverter = makeAddr("converter");
        address mockFlashLoan = makeAddr("flashLoan");
        address mockSwapper = makeAddr("swapper");

        V3Leverager leverager = new V3Leverager(owner);
        LeveragedVault vault = _deployLeveragedVault(
            address(leverager),
            mockConverter,
            mockFlashLoan,
            mockSwapper,
            owner
        );

        // Fund leverager with MYT and simulate deposit callback
        uint256 mytAmount = 50e18;
        uint256 shares = _fundWithMYT(address(leverager), mytAmount);

        // The leverager would normally call vaultDepositYieldTokens
        // Simulate: approve vault, then call as leverager
        vm.startPrank(address(leverager));
        IERC20(address(mytVault)).approve(address(vault), shares);
        uint256 deposited = vault.vaultDepositYieldTokens(shares);
        vm.stopPrank();

        // Position should exist
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should be created");

        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertEq(collateral, shares, "Collateral should match deposited MYT");
        assertEq(deposited, shares, "Return value should match");
    }

    function test_LocalStack_VaultMintDebtTokensFromRealAlchemist() public {
        address mockConverter = makeAddr("converter");
        address mockFlashLoan = makeAddr("flashLoan");
        address mockSwapper = makeAddr("swapper");

        V3Leverager leverager = new V3Leverager(owner);
        LeveragedVault vault = _deployLeveragedVault(
            address(leverager),
            mockConverter,
            mockFlashLoan,
            mockSwapper,
            owner
        );

        // Deposit MYT to create position
        uint256 shares = _fundWithMYT(address(leverager), 100e18);
        vm.startPrank(address(leverager));
        IERC20(address(mytVault)).approve(address(vault), shares);
        vault.vaultDepositYieldTokens(shares);
        vm.stopPrank();

        // Approve mint allowance (normally done by vault during leverage())
        uint256 posId = vault.getVaultPositionId();
        uint256 maxBorrow = alchemist.getMaxBorrowable(posId);
        uint256 mintAmount = maxBorrow / 2;

        // Simulate what leverage() does: vault calls approveMint on the alchemist
        vm.prank(address(vault));
        alchemist.approveMint(posId, address(leverager), mintAmount);

        // Mint debt tokens
        vm.prank(address(leverager));
        vault.vaultMintDebtTokens(mintAmount, address(leverager));

        (, uint256 debt,) = alchemist.getCDP(posId);
        assertEq(debt, mintAmount, "Debt should match");
        assertEq(IERC20(address(debtToken)).balanceOf(address(leverager)), mintAmount);
    }

    function test_LocalStack_VaultRepayWithYieldTokensOnRealAlchemist() public {
        address mockConverter = makeAddr("converter");
        address mockFlashLoan = makeAddr("flashLoan");
        address mockSwapper = makeAddr("swapper");

        V3Leverager leverager = new V3Leverager(owner);
        LeveragedVault vault = _deployLeveragedVault(
            address(leverager),
            mockConverter,
            mockFlashLoan,
            mockSwapper,
            owner
        );

        // Deposit + mint
        uint256 shares = _fundWithMYT(address(leverager), 100e18);
        vm.startPrank(address(leverager));
        IERC20(address(mytVault)).approve(address(vault), shares);
        vault.vaultDepositYieldTokens(shares);
        vm.stopPrank();

        uint256 posId = vault.getVaultPositionId();
        uint256 maxBorrow = alchemist.getMaxBorrowable(posId);
        uint256 mintAmount = maxBorrow / 2;

        vm.prank(address(vault));
        alchemist.approveMint(posId, address(leverager), mintAmount);

        vm.prank(address(leverager));
        vault.vaultMintDebtTokens(mintAmount, address(leverager));

        // Advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        // Repay with yield tokens (MYT)
        uint256 repayAmount = mintAmount / 2;
        // Fund leverager with MYT for repayment
        uint256 repayMyt = _fundWithMYT(address(leverager), repayAmount);
        vm.startPrank(address(leverager));
        IERC20(address(mytVault)).approve(address(vault), repayMyt);
        vault.vaultRepayWithYieldTokens(repayMyt);
        vm.stopPrank();

        (, uint256 debtAfter,) = alchemist.getCDP(posId);
        assertLt(debtAfter, mintAmount, "Debt should decrease after repay");
    }

    function test_LocalStack_VaultWithdrawYieldTokensFromRealAlchemist() public {
        address mockConverter = makeAddr("converter");
        address mockFlashLoan = makeAddr("flashLoan");
        address mockSwapper = makeAddr("swapper");

        V3Leverager leverager = new V3Leverager(owner);
        LeveragedVault vault = _deployLeveragedVault(
            address(leverager),
            mockConverter,
            mockFlashLoan,
            mockSwapper,
            owner
        );

        // Deposit MYT
        uint256 shares = _fundWithMYT(address(leverager), 100e18);
        vm.startPrank(address(leverager));
        IERC20(address(mytVault)).approve(address(vault), shares);
        vault.vaultDepositYieldTokens(shares);
        vm.stopPrank();

        // Withdraw half
        uint256 withdrawAmount = shares / 2;
        vm.prank(address(leverager));
        uint256 withdrawn = vault.vaultWithdrawYieldTokens(withdrawAmount, address(leverager));

        assertEq(withdrawn, withdrawAmount, "Withdrawn amount should match request");

        uint256 posId = vault.getVaultPositionId();
        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertEq(collateral, shares - withdrawAmount, "Collateral should decrease");
    }
}
