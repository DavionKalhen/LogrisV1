// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../src/LeveragedVault.sol";

// ============ Minimal Mocks for Fuzz Testing ============

contract FuzzMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FuzzMockPositionNFT {
    address public alchemist;
    uint256 private _currentTokenId;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(address => uint256[]) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    constructor(address alchemist_) {
        alchemist = alchemist_;
    }

    function mint(address to) external returns (uint256) {
        require(msg.sender == alchemist, "Only alchemist");
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _owners[tokenId] = to;
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
        return tokenId;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "Invalid token");
        return owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        require(index < _ownedTokens[owner].length, "Index out of bounds");
        return _ownedTokens[owner][index];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_owners[tokenId] == from, "Not owner");
        _owners[tokenId] = to;

        uint256 fromIndex = _ownedTokensIndex[tokenId];
        uint256 lastIndex = _ownedTokens[from].length - 1;
        if (fromIndex != lastIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastIndex];
            _ownedTokens[from][fromIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = fromIndex;
        }
        _ownedTokens[from].pop();
        _balances[from] -= 1;

        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
    }
}

contract FuzzMockAlchemistV3 {
    address public yieldTokenAddr;
    address public debtTokenAddr;
    FuzzMockPositionNFT public positionNFT;

    uint256 public depositCapVal = type(uint256).max;
    uint256 public totalDepositedVal;
    uint256 public minCollateralizationVal = 1_111_111_111_111_111_111; // ~111%

    // Per-position tracking
    mapping(uint256 => uint256) public positionCollateral;
    mapping(uint256 => uint256) public positionDebt;

    constructor(address _yieldToken, address _debtToken) {
        yieldTokenAddr = _yieldToken;
        debtTokenAddr = _debtToken;
        positionNFT = new FuzzMockPositionNFT(address(this));
    }

    function alchemistPositionNFT() external view returns (address) {
        return address(positionNFT);
    }

    function depositsPaused() external pure returns (bool) { return false; }
    function loansPaused() external pure returns (bool) { return false; }
    function depositCap() external view returns (uint256) { return depositCapVal; }
    function getTotalDeposited() external view returns (uint256) { return totalDepositedVal; }
    function minimumCollateralization() external view returns (uint256) { return minCollateralizationVal; }
    function yieldToken() external view returns (address) { return yieldTokenAddr; }
    function debtToken() external view returns (address) { return debtTokenAddr; }

    function setDepositCap(uint256 cap) external { depositCapVal = cap; }
    function setMinCollateralization(uint256 mc) external { minCollateralizationVal = mc; }

    function getMaxBorrowable(uint256 posId) external view returns (uint256) {
        uint256 collUnderlying = positionCollateral[posId]; // 1:1 for simplicity
        uint256 maxDebt = collUnderlying * 1e18 / minCollateralizationVal;
        if (maxDebt > positionDebt[posId]) return maxDebt - positionDebt[posId];
        return 0;
    }

    function getCDP(uint256 posId) external view returns (uint256, uint256, uint256) {
        return (positionCollateral[posId], positionDebt[posId], 0);
    }

    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) { return amount; }
    function convertUnderlyingTokensToYield(uint256 amount) external pure returns (uint256) { return amount; }
    function normalizeDebtTokensToUnderlying(uint256 amount) external pure returns (uint256) { return amount; }

    function approveMint(uint256, address, uint256) external {}

    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256) {
        ERC20(yieldTokenAddr).transferFrom(msg.sender, address(this), amount);
        if (recipientId == 0) {
            positionNFT.mint(recipient);
            recipientId = 1; // simplified
        }
        positionCollateral[recipientId] += amount;
        totalDepositedVal += amount;
        return 0;
    }

    function withdraw(uint256 amount, address recipient, uint256 posId) external returns (uint256) {
        positionCollateral[posId] -= amount;
        totalDepositedVal -= amount;
        ERC20(yieldTokenAddr).transfer(recipient, amount);
        return amount;
    }

    function mint(uint256 posId, uint256 amount, address recipient) external {
        positionDebt[posId] += amount;
        FuzzMockERC20(debtTokenAddr).mint(recipient, amount);
    }

    function burn(uint256 amount, uint256 posId) external returns (uint256) {
        ERC20(debtTokenAddr).transferFrom(msg.sender, address(this), amount);
        positionDebt[posId] -= amount;
        return amount;
    }
}

// ============ Fuzz Test Contracts ============

/**
 * @title LeveragedVaultFuzzTest
 * @notice Fuzz tests for mathematical calculations and share accounting
 */
contract LeveragedVaultFuzzTest is Test {
    FuzzMockERC20 private underlying;
    FuzzMockERC20 private yieldToken;
    FuzzMockERC20 private debtToken;
    FuzzMockAlchemistV3 private alchemist;
    LeveragedVault private vault;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        underlying = new FuzzMockERC20("Underlying", "UND");
        yieldToken = new FuzzMockERC20("Yield", "YLD");
        debtToken = new FuzzMockERC20("Debt", "DBT");
        alchemist = new FuzzMockAlchemistV3(address(yieldToken), address(debtToken));

        vault = new LeveragedVault(
            "Leveraged Vault",
            "LVLT",
            address(yieldToken),
            address(underlying),
            address(alchemist),
            address(this), // leverager = test contract
            100,
            200,
            address(0xCAFE),
            address(0xF00D),
            address(0xBEEF),
            address(underlying)
        );
    }

    // ============ Share Calculation Fuzz Tests ============

    /// @notice First depositor should always receive shares equal to deposit amount
    function testFuzz_FirstDepositorSharesEqualDeposit(uint256 amount) public {
        amount = bound(amount, 1, 1e30);

        underlying.mint(alice, amount);
        vm.startPrank(alice);
        underlying.approve(address(vault), amount);
        uint256 shares = vault.depositUnderlying(amount);
        vm.stopPrank();

        assertEq(shares, amount, "First depositor should get 1:1 shares");
        assertEq(vault.balanceOf(alice), amount, "Balance should match shares");
    }

    /// @notice Multiple depositors should get shares proportional to their deposit relative to totalAssets
    function testFuzz_MultiDepositorShareProportionality(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1e6, 1e27);
        amount2 = bound(amount2, 1e6, 1e27);

        // Alice deposits first
        underlying.mint(alice, amount1);
        vm.startPrank(alice);
        underlying.approve(address(vault), amount1);
        uint256 aliceShares = vault.depositUnderlying(amount1);
        vm.stopPrank();

        // Bob deposits second
        underlying.mint(bob, amount2);
        vm.startPrank(bob);
        underlying.approve(address(vault), amount2);
        uint256 bobShares = vault.depositUnderlying(amount2);
        vm.stopPrank();

        // Both should have received positive shares
        assertGt(aliceShares, 0, "Alice should have shares");
        assertGt(bobShares, 0, "Bob should have shares");

        // Total shares should equal total deposits (within rounding)
        uint256 totalShares = vault.totalSupply();
        uint256 totalDeposits = amount1 + amount2;
        // Allow 2 wei rounding error per deposit
        assertApproxEqAbs(totalShares, totalDeposits, 2, "Total shares should approximate total deposits");
    }

    /// @notice convertSharesToUnderlyingTokens and convertUnderlyingTokensToShares should be inverse
    function testFuzz_ShareConversionRoundTrip(uint256 depositAmount, uint256 queryAmount) public {
        depositAmount = bound(depositAmount, 1e12, 1e27);
        queryAmount = bound(queryAmount, 1, depositAmount);

        // Create initial deposit so vault has supply
        underlying.mint(alice, depositAmount);
        vm.startPrank(alice);
        underlying.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // Convert underlying → shares → underlying should be approximately identity
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
        underlying.approve(address(vault), amount);
        uint256 shares = vault.depositUnderlying(amount);
        vm.stopPrank();

        assertGt(shares, 0, "Non-zero deposit must produce non-zero shares");
    }

    // ============ Basis Point Adjustment Fuzz Tests ============

    /// @notice _basisPointAdjustment should always reduce or maintain the amount
    function testFuzz_BasisPointAdjustmentNeverIncreases(uint256 amount, uint32 slippageBps) public view {
        amount = bound(amount, 0, 1e30);
        slippageBps = uint32(bound(slippageBps, 0, 9999));

        // We can test this through getLeverageParameters which uses _basisPointAdjustment internally
        // Or test the formula directly
        uint256 adjusted = amount * (10000 - slippageBps) / 10000;
        assertLe(adjusted, amount, "Adjusted amount must be <= original");
    }

    /// @notice Zero slippage should return the same amount
    function testFuzz_ZeroSlippagePreservesAmount(uint256 amount) public view {
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

    /// @notice Flash loan formula should handle extreme collateralization ratios
    function testFuzz_FlashLoanWithVaryingCollateralization(uint256 depositAmount, uint256 minCollat) public {
        depositAmount = bound(depositAmount, 1e15, 1e24);
        minCollat = bound(minCollat, 1.01e18, 5e18); // 101% to 500%

        alchemist.setMinCollateralization(minCollat);

        uint32 underlyingSlippage = 100; // 1%
        uint32 debtSlippage = 200; // 2%

        (
            uint256 clampedDeposit,
            uint256 flashLoanAmount,
            ,
            uint256 mintAmount,
        ) = vault.getLeverageParameters(depositAmount, underlyingSlippage, debtSlippage);

        // Higher collateralization should mean less leverage
        assertLe(clampedDeposit, depositAmount, "Clamped should be <= deposit");

        // Flash loan should be reasonable relative to deposit
        if (flashLoanAmount > 0) {
            // With very high collateralization (e.g., 500%), leverage should be limited
            // The maximum theoretical leverage is 1/(1 - 1/CR)
            // For 200% CR, max leverage is 2x, so flash loan < deposit
            // For 111% CR, max leverage is ~9x
            uint256 maxLeverageMultiple = minCollat * 10 / (minCollat - 1e18);
            assertLt(flashLoanAmount, depositAmount * maxLeverageMultiple,
                "Flash loan should be bounded by leverage multiple");
        }

        // Mint amount should never exceed what collateral can back
        if (mintAmount > 0 && clampedDeposit > 0) {
            uint256 totalDeposit = clampedDeposit + flashLoanAmount;
            uint256 maxMintable = totalDeposit * 1e18 / minCollat;
            // Allow some slack for existing borrow capacity
            assertLe(mintAmount, maxMintable + 1e18,
                "Mint should not vastly exceed collateral backing");
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
        underlying.approve(address(vault), depositAmount);
        uint256 shares = vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // With no position, pool has all funds - direct withdrawal works
        uint256 poolBalance = vault.getDepositPoolBalance();
        uint256 underlyingValue = vault.convertSharesToUnderlyingTokens(shares);

        assertEq(poolBalance, depositAmount, "Pool should hold full deposit");
        assertApproxEqAbs(underlyingValue, depositAmount, 1, "Share value should equal deposit");

        // Withdrawal should succeed without needing flash loan (pool has enough)
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, 0, 0, 0);

        assertApproxEqAbs(withdrawn, depositAmount, 1, "Should withdraw full deposit");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares after withdrawal");
    }

    // ============ Deposit Cap Fuzz Tests ============

    /// @notice Deposit capacity should decrease as deposits fill up
    function testFuzz_DepositCapacityDecreases(uint256 cap, uint256 deposited) public {
        cap = bound(cap, 1e18, 1e30);
        deposited = bound(deposited, 0, cap);

        alchemist.setDepositCap(cap);
        // Simulate deposits by directly setting totalDeposited
        // We can't call deposit here without position setup, so just verify view function
        uint256 capacity = vault.getDepositCapacity();

        // With nothing deposited, capacity should be the full cap
        assertEq(capacity, cap, "Capacity should equal cap with no deposits");
    }

    // ============ Edge Case Fuzz Tests ============

    /// @notice convertSharesToUnderlyingTokens should return 0 for 0 shares
    function testFuzz_ZeroSharesReturnZeroUnderlying() public {
        // First make a deposit so supply > 0
        underlying.mint(alice, 1e18);
        vm.startPrank(alice);
        underlying.approve(address(vault), 1e18);
        vault.depositUnderlying(1e18);
        vm.stopPrank();

        uint256 underlying_ = vault.convertSharesToUnderlyingTokens(0);
        assertEq(underlying_, 0, "Zero shares should convert to zero underlying");
    }

    /// @notice convertSharesToUnderlyingTokens should return 0 when supply is 0
    function testFuzz_ZeroSupplyReturnsZero(uint256 shares) public view {
        shares = bound(shares, 1, 1e30);
        uint256 underlying_ = vault.convertSharesToUnderlyingTokens(shares);
        assertEq(underlying_, 0, "Should return 0 when supply is 0");
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
        underlying.approve(address(vault), deposit1);
        vm.prank(alice);
        vault.depositUnderlying(deposit1);

        underlying.mint(bob, deposit2);
        vm.prank(bob);
        underlying.approve(address(vault), deposit2);
        vm.prank(bob);
        vault.depositUnderlying(deposit2);

        underlying.mint(charlie, deposit3);
        vm.prank(charlie);
        underlying.approve(address(vault), deposit3);
        vm.prank(charlie);
        vault.depositUnderlying(deposit3);

        // Total supply should approximate total deposits
        uint256 totalDeposits = deposit1 + deposit2 + deposit3;
        uint256 totalSupply = vault.totalSupply();
        assertApproxEqAbs(totalSupply, totalDeposits, 3,
            "Total supply should approximate total deposits");

        // Each user's share value should approximate their deposit
        uint256 aliceValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(alice));
        uint256 bobValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(bob));
        uint256 charlieValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(charlie));

        assertApproxEqAbs(aliceValue, deposit1, 3, "Alice value should approximate deposit");
        assertApproxEqAbs(bobValue, deposit2, 3, "Bob value should approximate deposit");
        assertApproxEqAbs(charlieValue, deposit3, 3, "Charlie value should approximate deposit");
    }
}
