// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LocalAlchemistV3Base.t.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/converters/MYTConverter.sol";
import "../src/interfaces/ISwapper.sol";
import {IFlashLoanAdapter} from "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import {IFlashLoanCallback} from "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// ============================================================================
// Shared Mocks (used by multiple test files)
// ============================================================================

/// @dev Flash loan adapter that mints underlying for the loan, charges zero fee.
///      Uses MockERC20WithMetadata.mint() since the local test stack doesn't have
///      a real lending pool with liquidity.
contract LocalFlashLoanAdapter is IFlashLoanAdapter {
    using SafeERC20 for IERC20;

    address public immutable underlyingToken;

    constructor(address _underlyingToken) {
        underlyingToken = _underlyingToken;
    }

    function flashLoan(
        address _token,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external override {
        // Mint underlying for the flash loan
        MockERC20WithMetadata(_token).mint(address(this), amount);
        IERC20(_token).safeTransfer(recipient, amount);

        // Callback
        IFlashLoanCallback(recipient).onFlashLoanReceived(
            msg.sender,
            _token,
            amount,
            0, // zero fee
            data
        );

        // Verify repayment
        require(IERC20(_token).balanceOf(address(this)) >= amount, "Flash loan not repaid");

        emit FlashLoanExecuted(_token, amount, 0, recipient);
    }

    function getFlashLoanFee(address, uint256) external pure override returns (uint256) { return 0; }
    function isTokenSupported(address) external pure override returns (bool) { return true; }
    function maxFlashLoan(address) external pure override returns (uint256) { return type(uint256).max; }
    function getProvider() external view override returns (address) { return address(this); }
}

/// @dev 1:1 swapper that mints debt tokens for the swap (swapDebtToUnderlying).
///      Used during leverage: after minting debt tokens, the leverager swaps them for underlying.
///      This mock simulates a 1:1 swap by burning debt and minting underlying.
contract LocalSwapper is ISwapper {
    address public debtToken;
    address public underlyingToken;

    constructor(address _debtToken, address _underlyingToken) {
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
    }

    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        // Pull debt tokens from caller
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        // Mint equivalent underlying to recipient (1:1)
        MockERC20WithMetadata(underlyingToken).mint(recipient, debtAmount);
        return debtAmount;
    }

    function swapUnderlyingToDebt(uint256, uint256, address, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount) external pure override returns (uint256, uint256) {
        return (debtAmount, debtAmount);
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount) external pure override returns (uint256, uint256) {
        return (underlyingAmount, underlyingAmount);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 1e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 1e18; }
    function getSwapFee() external pure override returns (uint256) { return 0; }
    function getSlippageTolerance() external pure override returns (uint256) { return 100; }

    function isSupportedPair(address tokenA, address tokenB) external view override returns (bool) {
        return (tokenA == debtToken && tokenB == underlyingToken)
            || (tokenA == underlyingToken && tokenB == debtToken);
    }
}

// ============================================================================
// LogrisTestBase - Shared base for tests that need full Logris + AlchemistV3 stack
// ============================================================================

/// @title LogrisTestBase
/// @notice Extends LocalAlchemistV3Base with the complete Logris stack (leverager, converter,
///         flash loan adapter, swapper, and a LeveragedVault clone).
///         Tests inheriting from this get a fully functional system with real AlchemistV3.
abstract contract LogrisTestBase is LocalAlchemistV3Base {
    V3Leverager public leverager;
    MYTConverter public converter;
    LocalFlashLoanAdapter public flashLoanAdapter;
    LocalSwapper public swapper;
    LeveragedVault public vault;

    address public owner;
    address public alice;
    address public bob;

    /// @notice Deploys the full Logris stack on top of LocalAlchemistV3Base.
    ///         Call this from your test's setUp() after _deployLocalAlchemistV3().
    function _deployLogrisStack() internal {
        _deployLocalAlchemistV3();

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy leverager
        leverager = new V3Leverager(owner);

        // Deploy MYT converter (underlying <-> MYT via VaultV2)
        converter = new MYTConverter(address(mytVault), address(underlying));

        // Deploy flash loan adapter
        flashLoanAdapter = new LocalFlashLoanAdapter(address(underlying));

        // Deploy 1:1 swapper (for leverage path)
        swapper = new LocalSwapper(address(debtToken), address(underlying));

        // Deploy leveraged vault
        vault = _deployLeveragedVault(
            address(leverager),
            address(converter),
            address(flashLoanAdapter),
            address(swapper),
            owner
        );

        // Approve adapters on leverager
        vm.startPrank(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        leverager.setSwapperApproval(address(swapper), true);
        // Whitelist test contract and test users for leverage operations
        vault.setLeverageWhitelist(address(this), true);
        vault.setLeverageWhitelist(alice, true);
        vault.setLeverageWhitelist(bob, true);
        vm.stopPrank();
    }

    // ============ Helpers ============

    /// @dev Deposits underlying into vault as `user`, returns shares received.
    function _depositFor(address user, uint256 amount) internal returns (uint256 shares) {
        underlying.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(underlying)).approve(address(vault), amount);
        shares = vault.depositUnderlying(amount);
        vm.stopPrank();
    }

    /// @dev Deposits underlying and executes leverage with auto-computed parameters.
    function _depositAndLeverage(address user, uint256 amount) internal returns (uint256 shares) {
        underlying.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(underlying)).approve(address(vault), amount);
        shares = vault.depositAndLeverageAtomic(amount, 100, 200, 0);
        vm.stopPrank();
    }

    /// @dev Pause/unpause deposits on AlchemistV3.
    function _pauseDeposits(bool paused) internal {
        vm.prank(alchemistAdmin);
        alchemist.pauseDeposits(paused);
    }

    /// @dev Pause/unpause loans on AlchemistV3.
    function _pauseLoans(bool paused) internal {
        vm.prank(alchemistAdmin);
        alchemist.pauseLoans(paused);
    }

    /// @dev Set deposit cap on AlchemistV3.
    function _setDepositCap(uint256 cap) internal {
        vm.prank(alchemistAdmin);
        alchemist.setDepositCap(cap);
    }
}
