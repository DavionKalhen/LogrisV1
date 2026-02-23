// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LogrisTestBase.t.sol";
import {IAlchemistV3Position} from "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

/// @title VaultPositionInvariantTest
/// @notice Tests for position NFT invariants (PositionAlreadyExists, sweepUnknownPosition)
///         using the real AlchemistV3 stack.
/// @dev Deploys a vault with leverager=address(this) so the test contract can call
///      vaultDepositYieldTokens directly to exercise the position guards.
contract VaultPositionInvariantTest is LocalAlchemistV3Base {
    LeveragedVault private testVault;

    function setUp() public {
        _deployLocalAlchemistV3();

        // Deploy a vault where the test contract is the leverager so we can call
        // vaultDepositYieldTokens directly (it has onlyLeverager modifier).
        testVault = _deployLeveragedVault(
            address(this),       // leverager = test contract
            address(0xCAFE),     // converter (unused in these tests)
            address(0xF00D),     // flashLoanAdapter (unused)
            address(0xBEEF),     // swapper (unused)
            address(this)        // owner = test contract
        );
    }

    /// @dev Fund this test contract with MYT tokens and approve the vault.
    function _mintMYT(uint256 underlyingAmount) internal returns (uint256 mytShares) {
        mytShares = _fundWithMYT(address(this), underlyingAmount);
        IERC20(address(mytVault)).approve(address(testVault), mytShares);
    }

    /// @notice If the vault already holds a position NFT (e.g., from a rogue deposit),
    ///         calling vaultDepositYieldTokens should revert with PositionAlreadyExists.
    function test_RevertIfPositionAlreadyExists() public {
        // Fund this contract with MYT for the vaultDepositYieldTokens call
        uint256 mytShares = _mintMYT(10 ether);

        // Create a rogue position for the vault by depositing MYT to alchemist
        // with testVault as recipient. This mints a position NFT to testVault
        // that the vault doesn't know about (vaultPositionId == 0).
        uint256 rogueMYT = _fundWithMYT(address(this), 10 ether);
        IERC20(address(mytVault)).approve(address(alchemist), rogueMYT);
        vm.prank(address(this));
        alchemist.deposit(rogueMYT, address(testVault), 0);

        // Verify testVault now holds a position NFT but doesn't know about it
        IAlchemistV3Position nft = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        assertGt(nft.balanceOf(address(testVault)), 0, "Vault should hold a rogue position NFT");
        assertEq(testVault.vaultPositionId(), 0, "Vault should not know about the position");

        // Now vaultDepositYieldTokens should revert because it detects
        // positionNFT.balanceOf(vault) != 0 but vaultPositionId == 0
        vm.expectRevert(LeveragedVault.PositionAlreadyExists.selector);
        testVault.vaultDepositYieldTokens(mytShares);
    }

    /// @notice After creating a real position, if an extra position NFT is minted to the vault,
    ///         the owner can sweep the unknown position but not the active one.
    function test_SweepUnknownPosition() public {
        // 1. Create the vault's own position via vaultDepositYieldTokens
        uint256 mytShares = _mintMYT(10 ether);
        testVault.vaultDepositYieldTokens(mytShares);

        uint256 activeId = testVault.getVaultPositionId();
        assertGt(activeId, 0, "Active position should exist");

        // 2. Create an extra rogue position for the vault
        uint256 rogueMYT = _fundWithMYT(address(this), 10 ether);
        IERC20(address(mytVault)).approve(address(alchemist), rogueMYT);
        alchemist.deposit(rogueMYT, address(testVault), 0);

        IAlchemistV3Position nft = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        assertEq(nft.balanceOf(address(testVault)), 2, "Vault should hold 2 position NFTs");

        // Find the extra position ID (it's not the active one)
        uint256 extraId;
        for (uint256 i = 0; i < nft.balanceOf(address(testVault)); i++) {
            uint256 tokenId = nft.tokenOfOwnerByIndex(address(testVault), i);
            if (tokenId != activeId) {
                extraId = tokenId;
                break;
            }
        }
        assertGt(extraId, 0, "Should find an extra position ID");

        // 3. Cannot sweep the active position
        vm.expectRevert(LeveragedVault.CannotSweepActivePosition.selector);
        testVault.sweepUnknownPosition(activeId, address(0xBEEF));

        // 4. Can sweep the unknown/extra position
        testVault.sweepUnknownPosition(extraId, address(0xBEEF));
        assertEq(nft.ownerOf(extraId), address(0xBEEF), "Extra position should be swept to recipient");
        assertEq(nft.balanceOf(address(testVault)), 1, "Vault should have only 1 position NFT");
    }
}
