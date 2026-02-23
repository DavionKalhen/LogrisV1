// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LocalAlchemistV3Base.t.sol";
import "../src/converters/MYTConverter.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MYTConverterTest is LocalAlchemistV3Base {
    MYTConverter public converter;
    address public alice;

    function setUp() public {
        _deployLocalAlchemistV3();
        converter = new MYTConverter(address(mytVault), address(underlying));
        alice = makeAddr("alice");
    }

    // ============ Getter Tests ============

    function test_yieldToken_returnsMYTAddress() public view {
        assertEq(converter.yieldToken(), address(mytVault));
    }

    function test_underlyingToken_returnsCorrectAddress() public view {
        assertEq(converter.underlyingToken(), address(underlying));
    }

    // ============ Constructor Tests ============

    function test_constructor_revertsZeroVaultV2() public {
        vm.expectRevert(MYTConverter.ZeroAddress.selector);
        new MYTConverter(address(0), address(underlying));
    }

    function test_constructor_revertsZeroUnderlying() public {
        vm.expectRevert(MYTConverter.ZeroAddress.selector);
        new MYTConverter(address(mytVault), address(0));
    }

    // ============ toYield Tests ============

    function test_toYield_convertsUnderlyingToMYT() public {
        uint256 amount = 100e18;
        _fundWithUnderlying(alice, amount);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(converter), amount);
        uint256 mytAmount = converter.toYield(amount, alice, 0);
        vm.stopPrank();

        assertGt(mytAmount, 0, "Should receive MYT shares");
        assertEq(IERC20(address(mytVault)).balanceOf(alice), mytAmount, "Alice should hold MYT");
        assertEq(underlying.balanceOf(alice), 0, "All underlying should be consumed");
    }

    function test_toYield_respectsMinOut() public {
        uint256 amount = 100e18;
        _fundWithUnderlying(alice, amount);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(converter), amount);
        vm.expectRevert(MYTConverter.InsufficientYieldOutput.selector);
        converter.toYield(amount, alice, type(uint256).max);
        vm.stopPrank();
    }

    function test_toYield_sendsToRecipient() public {
        uint256 amount = 50e18;
        address bob = makeAddr("bob");
        _fundWithUnderlying(alice, amount);

        vm.startPrank(alice);
        IERC20(address(underlying)).approve(address(converter), amount);
        uint256 mytAmount = converter.toYield(amount, bob, 0);
        vm.stopPrank();

        assertEq(IERC20(address(mytVault)).balanceOf(bob), mytAmount, "Bob should hold MYT");
        assertEq(IERC20(address(mytVault)).balanceOf(alice), 0, "Alice should hold no MYT");
    }

    // ============ toUnderlying Tests ============

    /// @dev Helper: get MYT shares with liquid underlying in VaultV2 (via converter.toYield, not strategy allocation)
    function _getMYTWithLiquidity(address to, uint256 underlyingAmount) internal returns (uint256 mytShares) {
        _fundWithUnderlying(to, underlyingAmount);
        vm.startPrank(to);
        IERC20(address(underlying)).approve(address(converter), underlyingAmount);
        mytShares = converter.toYield(underlyingAmount, to, 0);
        vm.stopPrank();
    }

    function test_toUnderlying_convertsMYTToUnderlying() public {
        uint256 amount = 100e18;
        uint256 mytShares = _getMYTWithLiquidity(alice, amount);

        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(converter), mytShares);
        uint256 underlyingOut = converter.toUnderlying(mytShares, alice, 0);
        vm.stopPrank();

        assertGt(underlyingOut, 0, "Should receive underlying");
        assertEq(underlying.balanceOf(alice), underlyingOut, "Alice should hold underlying");
        assertEq(IERC20(address(mytVault)).balanceOf(alice), 0, "All MYT should be consumed");
    }

    function test_toUnderlying_respectsMinOut() public {
        uint256 amount = 100e18;
        uint256 mytShares = _getMYTWithLiquidity(alice, amount);

        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(converter), mytShares);
        vm.expectRevert(MYTConverter.InsufficientUnderlyingOutput.selector);
        converter.toUnderlying(mytShares, alice, type(uint256).max);
        vm.stopPrank();
    }

    function test_toUnderlying_sendsToRecipient() public {
        uint256 amount = 50e18;
        address bob = makeAddr("bob");
        uint256 mytShares = _getMYTWithLiquidity(alice, amount);

        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(converter), mytShares);
        uint256 underlyingOut = converter.toUnderlying(mytShares, bob, 0);
        vm.stopPrank();

        assertEq(underlying.balanceOf(bob), underlyingOut, "Bob should hold underlying");
    }

    // ============ Round-trip Tests ============

    function test_roundTrip_preservesValue() public {
        uint256 amount = 100e18;
        uint256 mytShares = _getMYTWithLiquidity(alice, amount);

        // MYT → underlying
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(converter), mytShares);
        uint256 underlyingBack = converter.toUnderlying(mytShares, alice, 0);
        vm.stopPrank();

        // Should be approximately equal (rounding allowed)
        assertApproxEqAbs(underlyingBack, amount, 1, "Round-trip should preserve value");
    }

    // ============ Preview Tests ============

    function test_previewToYield_matchesVaultV2() public view {
        uint256 amount = 100e18;
        uint256 preview = converter.previewToYield(amount);
        uint256 vaultPreview = mytVault.convertToShares(amount);
        assertEq(preview, vaultPreview, "Preview should match VaultV2");
    }

    function test_previewToUnderlying_matchesVaultV2() public view {
        uint256 mytAmount = 100e18;
        uint256 preview = converter.previewToUnderlying(mytAmount);
        uint256 vaultPreview = mytVault.convertToAssets(mytAmount);
        assertEq(preview, vaultPreview, "Preview should match VaultV2");
    }
}
