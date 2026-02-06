// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Concrete implementation of ERC4626 for testing
contract TestERC4626Vault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Test Vault", "vTEST") {}

    // Expose internal functions for testing
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }
}

// Mock ERC20 token for testing
contract MockAsset is ERC20 {
    constructor() ERC20("Mock Asset", "MOCK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ERC4626Test is Test {
    TestERC4626Vault public vault;
    MockAsset public asset;

    address public user1 = address(0x100);
    address public user2 = address(0x200);
    address public user3 = address(0x300);

    function setUp() public {
        asset = new MockAsset();
        vault = new TestERC4626Vault(IERC20(address(asset)));

        // Fund users
        asset.transfer(user1, 10000 ether);
        asset.transfer(user2, 10000 ether);
        asset.transfer(user3, 10000 ether);
    }

    // ===== DEPOSIT TESTS =====

    function testDeposit() public {
        vm.startPrank(user1);
        uint256 depositAmount = 100 ether;

        asset.approve(address(vault), depositAmount);
        uint256 sharesBefore = vault.balanceOf(user1);

        uint256 shares = vault.deposit(depositAmount, user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(user1), sharesBefore + shares, "Balance should increase by shares");
        assertEq(asset.balanceOf(address(vault)), depositAmount, "Vault should hold assets");

        vm.stopPrank();
    }

    function testDepositZeroAmount() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 0);

        uint256 shares = vault.deposit(0, user1);
        assertEq(shares, 0, "Should receive 0 shares for 0 deposit");

        vm.stopPrank();
    }

    function testDepositToAnotherAddress() public {
        vm.startPrank(user1);
        uint256 depositAmount = 100 ether;

        asset.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user2);

        assertEq(vault.balanceOf(user1), 0, "User1 should have no shares");
        assertEq(vault.balanceOf(user2), shares, "User2 should receive shares");

        vm.stopPrank();
    }

    function testMultipleDeposits() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 300 ether);

        uint256 shares1 = vault.deposit(100 ether, user1);
        uint256 shares2 = vault.deposit(100 ether, user1);
        uint256 shares3 = vault.deposit(100 ether, user1);

        assertEq(vault.balanceOf(user1), shares1 + shares2 + shares3, "Total shares should be sum of deposits");
        assertEq(asset.balanceOf(address(vault)), 300 ether, "Vault should hold all assets");

        vm.stopPrank();
    }

    // ===== WITHDRAW TESTS =====

    function testWithdraw() public {
        vm.startPrank(user1);
        uint256 depositAmount = 100 ether;
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);

        uint256 withdrawAmount = 50 ether;
        uint256 balanceBefore = asset.balanceOf(user1);

        vault.withdraw(withdrawAmount, user1, user1);

        uint256 balanceAfter = asset.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Should receive withdrawn assets");

        vm.stopPrank();
    }

    function testWithdrawAll() public {
        vm.startPrank(user1);
        uint256 depositAmount = 100 ether;
        asset.approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user1);

        uint256 maxWithdraw = vault.maxWithdraw(user1);
        vault.withdraw(maxWithdraw, user1, user1);

        assertEq(vault.balanceOf(user1), 0, "Should have no shares left");

        vm.stopPrank();
    }

    // ===== CONVERSION TESTS =====

    function testConvertToShares() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user1);
        vm.stopPrank();

        uint256 shares = vault.convertToShares(50 ether);
        assertGt(shares, 0, "Should convert to positive shares");
    }

    function testConvertToAssets() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares = vault.deposit(100 ether, user1);
        vm.stopPrank();

        uint256 assets = vault.convertToAssets(shares / 2);
        assertGt(assets, 0, "Should convert to positive assets");
    }

    function testConvertToSharesZeroSupply() public {
        // When supply is 0, convertToShares should return the asset amount
        uint256 shares = vault.convertToShares(100 ether);
        assertEq(shares, 100 ether, "Should return 1:1 when supply is 0");
    }

    // ===== MAX FUNCTIONS TESTS =====

    function testMaxDeposit() public {
        uint256 maxDeposit = vault.maxDeposit(user1);
        assertEq(maxDeposit, type(uint256).max, "Max deposit should be uint256 max");
    }

    function testMaxWithdraw() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user1);
        vm.stopPrank();

        uint256 maxWithdraw = vault.maxWithdraw(user1);
        assertGt(maxWithdraw, 0, "Max withdraw should be positive after deposit");
    }

    function testMaxWithdrawNoDeposit() public {
        uint256 maxWithdraw = vault.maxWithdraw(user1);
        assertEq(maxWithdraw, 0, "Max withdraw should be 0 with no deposit");
    }

    function testMaxMint() public {
        uint256 maxMint = vault.maxMint(user1);
        assertEq(maxMint, type(uint256).max, "Max mint should be uint256 max");
    }

    function testMaxRedeem() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares = vault.deposit(100 ether, user1);
        vm.stopPrank();

        uint256 maxRedeem = vault.maxRedeem(user1);
        assertEq(maxRedeem, shares, "Max redeem should equal shares owned");
    }

    // ===== PREVIEW FUNCTIONS TESTS =====

    function testPreviewDeposit() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);

        uint256 expectedShares = vault.previewDeposit(100 ether);
        uint256 actualShares = vault.deposit(100 ether, user1);

        assertEq(expectedShares, actualShares, "Preview should match actual");

        vm.stopPrank();
    }

    function testPreviewMint() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 1000 ether);

        uint256 sharesToMint = 50 ether;
        uint256 expectedAssets = vault.previewMint(sharesToMint);

        assertGt(expectedAssets, 0, "Preview mint should return positive assets");

        vm.stopPrank();
    }

    function testPreviewWithdraw() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user1);

        uint256 expectedShares = vault.previewWithdraw(50 ether);
        assertGt(expectedShares, 0, "Preview withdraw should return positive shares");

        vm.stopPrank();
    }

    function testPreviewRedeem() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares = vault.deposit(100 ether, user1);

        uint256 expectedAssets = vault.previewRedeem(shares);
        assertGt(expectedAssets, 0, "Preview redeem should return positive assets");

        vm.stopPrank();
    }

    // ===== ASSET TESTS =====

    function testAsset() public {
        assertEq(vault.asset(), address(asset), "Asset should match");
    }

    function testTotalAssets() public {
        assertEq(vault.totalAssets(), 0, "Initial total assets should be 0");

        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        vault.deposit(100 ether, user1);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 100 ether, "Total assets should equal deposits");
    }

    // ===== DECIMALS TESTS =====

    function testDecimals() public {
        uint8 vaultDecimals = vault.decimals();
        uint8 assetDecimals = asset.decimals();

        assertEq(vaultDecimals, assetDecimals, "Vault decimals should match asset decimals");
    }

    // ===== MULTI-USER TESTS =====

    function testMultipleUsersDeposit() public {
        // User 1 deposits
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares1 = vault.deposit(100 ether, user1);
        vm.stopPrank();

        // User 2 deposits
        vm.startPrank(user2);
        asset.approve(address(vault), 200 ether);
        uint256 shares2 = vault.deposit(200 ether, user2);
        vm.stopPrank();

        // User 3 deposits
        vm.startPrank(user3);
        asset.approve(address(vault), 300 ether);
        uint256 shares3 = vault.deposit(300 ether, user3);
        vm.stopPrank();

        assertEq(vault.totalSupply(), shares1 + shares2 + shares3, "Total supply should be sum of shares");
        assertEq(vault.totalAssets(), 600 ether, "Total assets should be sum of deposits");
    }

    function testSharesProportionalToDeposit() public {
        // User 1 deposits 100
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares1 = vault.deposit(100 ether, user1);
        vm.stopPrank();

        // User 2 deposits 200 (2x user1)
        vm.startPrank(user2);
        asset.approve(address(vault), 200 ether);
        uint256 shares2 = vault.deposit(200 ether, user2);
        vm.stopPrank();

        // User 2 should have approximately 2x the shares of user 1
        // Allow small rounding differences
        assertGt(shares2, shares1, "User2 should have more shares");
        assertApproxEqRel(shares2, shares1 * 2, 0.01e18, "User2 should have ~2x shares");
    }

    // ===== REDEEM TESTS =====

    function testRedeem() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 100 ether);
        uint256 shares = vault.deposit(100 ether, user1);

        uint256 balanceBefore = asset.balanceOf(user1);
        uint256 assets = vault.redeem(shares, user1, user1);
        uint256 balanceAfter = asset.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, assets, "Should receive redeemed assets");
        assertEq(vault.balanceOf(user1), 0, "Should have no shares after full redeem");

        vm.stopPrank();
    }

    // ===== MINT TESTS =====

    function testMint() public {
        vm.startPrank(user1);
        asset.approve(address(vault), 1000 ether);

        uint256 sharesToMint = 100 ether;
        uint256 assets = vault.mint(sharesToMint, user1);

        assertEq(vault.balanceOf(user1), sharesToMint, "Should have minted shares");
        assertGt(assets, 0, "Should have spent assets");

        vm.stopPrank();
    }
}
