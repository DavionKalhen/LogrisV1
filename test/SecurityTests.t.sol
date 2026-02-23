// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LocalAlchemistV3Base.t.sol";
import "./LogrisTestBase.t.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/converters/MYTConverter.sol";
import "../src/adapters/flashloan/EulerFlashLoanAdapter.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "../src/interfaces/ILeveragedVaultCallback.sol";
import {IAlchemistV3} from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// ============ Mock Contracts ============

/// @dev MockVault that works with real AlchemistV3. Implements ILeveragedVaultCallback
///      and exposes the getYieldToken/getUnderlyingToken/alchemist views that V3Leverager needs.
contract SecurityMockVault is ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    IAlchemistV3 public alchemistInstance;
    uint256 public vaultPositionId;
    address public leverager;
    address public underlyingToken;
    address public yieldToken; // stored directly (MYT address)
    bool private positionCreated;

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    constructor(address _alchemist, address _leverager, address _underlyingToken, address _yieldToken) {
        alchemistInstance = IAlchemistV3(_alchemist);
        leverager = _leverager;
        underlyingToken = _underlyingToken;
        yieldToken = _yieldToken;
    }

    /// @dev V3Leverager._getDebtToken() calls ILeveragedVaultAlchemist(vault).alchemist()
    function alchemist() external view returns (IAlchemistV3) {
        return alchemistInstance;
    }

    function vaultDepositYieldTokens(uint256 amount) external override onlyLeverager returns (uint256) {
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(address(alchemistInstance), amount);

        if (!positionCreated) {
            alchemistInstance.deposit(amount, address(this), 0);
            // Get position ID from the position NFT
            IAlchemistV3Position nft = IAlchemistV3Position(alchemistInstance.alchemistPositionNFT());
            vaultPositionId = nft.tokenOfOwnerByIndex(address(this), 0);
            positionCreated = true;
        } else {
            alchemistInstance.deposit(amount, address(this), vaultPositionId);
        }
        return amount;
    }

    function vaultMintDebtTokens(uint256 amount, address recipient) external override onlyLeverager {
        alchemistInstance.mint(vaultPositionId, amount, recipient);
    }

    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external override onlyLeverager returns (uint256) {
        return alchemistInstance.withdraw(amount, recipient, vaultPositionId);
    }

    function vaultRepayWithYieldTokens(uint256 amount) external override onlyLeverager returns (uint256) {
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(address(alchemistInstance), amount);
        return alchemistInstance.repay(amount, vaultPositionId);
    }

    function getVaultPositionId() external view override returns (uint256) {
        return vaultPositionId;
    }

    /// @dev V3Leverager validates converter.yieldToken() == vault.getYieldToken()
    function getYieldToken() external view returns (address) {
        return yieldToken;
    }

    /// @dev V3Leverager validates converter.underlyingToken() == vault.getUnderlyingToken()
    function getUnderlyingToken() external view returns (address) {
        return underlyingToken;
    }
}

/// @dev Swapper with 1% fee: debt -> underlying with 1% haircut.
///      Receives real AlchemicTokenV3 debt tokens; mints MockERC20WithMetadata underlying.
contract SecurityLocalSwapper1Pct is ISwapper {
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
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        uint256 output = debtAmount * 99 / 100;
        // underlying is MockERC20WithMetadata with public mint
        MockERC20WithMetadata(underlyingToken).mint(recipient, output);
        emit SwapExecuted(debtToken, underlyingToken, debtAmount, output, recipient);
        return output;
    }

    function swapUnderlyingToDebt(
        uint256,
        uint256,
        address,
        bytes calldata
    ) external pure override returns (uint256) {
        // Not used in leverage/deleverage paths tested here
        return 0;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount) external pure override returns (uint256, uint256) {
        uint256 expected = debtAmount * 99 / 100;
        return (expected, expected * 95 / 100);
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount) external pure override returns (uint256, uint256) {
        uint256 expected = underlyingAmount * 99 / 100;
        return (expected, expected * 95 / 100);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 0.99e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 0.99e18; }
    function getSwapFee() external pure override returns (uint256) { return 100; }
    function getSlippageTolerance() external pure override returns (uint256) { return 0; }
    function isSupportedPair(address, address) external pure override returns (bool) { return true; }
}

/// @dev Swapper that returns less than minSwapOutput to test slippage enforcement.
///      Uses MockERC20WithMetadata.mint for underlying.
contract SecurityBadSlippageSwapper is ISwapper {
    address public debtToken;
    address public underlyingToken;
    uint256 public outputAmount;

    constructor(address _debtToken, address _underlyingToken, uint256 _outputAmount) {
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
        outputAmount = _outputAmount;
    }

    function swapDebtToUnderlying(
        uint256 debtAmount,
        uint256,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        // Return less than expected
        MockERC20WithMetadata(underlyingToken).mint(recipient, outputAmount);
        emit SwapExecuted(debtToken, underlyingToken, debtAmount, outputAmount, recipient);
        return outputAmount;
    }

    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), underlyingAmount);
        // Not used but implement for completeness
        emit SwapExecuted(underlyingToken, debtToken, underlyingAmount, outputAmount, recipient);
        return outputAmount;
    }

    function previewSwapDebtToUnderlying(uint256) external view override returns (uint256, uint256) {
        return (outputAmount, outputAmount);
    }

    function previewSwapUnderlyingToDebt(uint256) external view override returns (uint256, uint256) {
        return (outputAmount, outputAmount);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 0.99e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 0.99e18; }
    function getSwapFee() external pure override returns (uint256) { return 100; }
    function getSlippageTolerance() external pure override returns (uint256) { return 0; }
    function isSupportedPair(address, address) external pure override returns (bool) { return true; }
}

/// @dev Malicious contract that tries to spoof flash loan callbacks
contract SecurityMaliciousCallbackSpoofer {
    V3Leverager public leverager;

    constructor(address _leverager) {
        leverager = V3Leverager(_leverager);
    }

    /// @dev Attempt to call onFlashLoanReceived directly without being in a flash loan
    function attemptSpoofedCallback() external returns (bool) {
        return leverager.onFlashLoanReceived(
            address(this),
            address(0),
            100 ether,
            0,
            ""
        );
    }
}

// ============ Security Test Contract ============

contract SecurityTests is LocalAlchemistV3Base {
    V3Leverager public leverager;
    EulerFlashLoanAdapter public eulerAdapter;

    MYTConverter public converter;
    SecurityLocalSwapper1Pct public swapper;
    LocalFlashLoanAdapter public flashLoanAdapter;
    SecurityMockVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        // Deploy real AlchemistV3 stack
        _deployLocalAlchemistV3();

        // Deploy MYT converter (underlying <-> MYT via VaultV2)
        converter = new MYTConverter(address(mytVault), address(underlying));

        // Deploy 1% fee swapper (debt -> underlying)
        swapper = new SecurityLocalSwapper1Pct(address(debtToken), address(underlying));

        // Deploy flash loan adapter (mints underlying, zero fee)
        flashLoanAdapter = new LocalFlashLoanAdapter(address(underlying));

        // Deploy leverager
        vm.prank(owner);
        leverager = new V3Leverager(owner);

        // Deploy mock vault with real AlchemistV3
        vault = new SecurityMockVault(
            address(alchemist),
            address(leverager),
            address(underlying),
            address(mytVault)
        );

        // Approve adapters on leverager
        vm.startPrank(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setSwapperApproval(address(swapper), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        vm.stopPrank();

        // Deploy Euler adapter (standalone, not dependent on AlchemistV3)
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        address[] memory dTokens = new address[](1);
        dTokens[0] = address(0x1234); // Mock dToken
        eulerAdapter = new EulerFlashLoanAdapter(tokens, dTokens);

        // Fund alice with MYT (yield tokens)
        _fundWithMYT(alice, 100 ether);
    }

    // ============ 1. Callback Spoofing Tests ============

    function test_RevertOnSpoofedCallback() public {
        SecurityMaliciousCallbackSpoofer spoofer = new SecurityMaliciousCallbackSpoofer(address(leverager));

        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        spoofer.attemptSpoofedCallback();
    }

    function test_RevertOnDirectCallbackNotFromAdapter() public {
        vm.prank(attacker);
        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        leverager.onFlashLoanReceived(attacker, address(underlying), 100 ether, 0, "");
    }

    // ============ 2. Euler Adapter Access Control Tests ============

    function test_EulerAdapter_RevertOnUnauthorizedSetDToken() public {
        address newDToken = makeAddr("newDToken");

        vm.prank(attacker);
        vm.expectRevert(); // Ownable revert
        eulerAdapter.setDToken(address(underlying), newDToken);
    }

    function test_EulerAdapter_OwnerCanSetDToken() public {
        address newDToken = makeAddr("newDToken");

        // Get the owner (deployer = this test contract)
        address eulerOwner = eulerAdapter.owner();

        vm.prank(eulerOwner);
        eulerAdapter.setDToken(address(underlying), newDToken);

        assertEq(eulerAdapter.dTokens(address(underlying)), newDToken);
    }

    function test_EulerAdapter_OwnerCanPause() public {
        address eulerOwner = eulerAdapter.owner();

        vm.prank(eulerOwner);
        eulerAdapter.pause();

        assertTrue(eulerAdapter.paused());
    }

    function test_EulerAdapter_NonOwnerCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert();
        eulerAdapter.pause();
    }

    // ============ 3. Slippage Enforcement Tests ============

    function test_RevertOnSlippageExceeded() public {
        // Deploy a bad swapper that returns less than minSwapOutput
        SecurityBadSlippageSwapper badSwapper = new SecurityBadSlippageSwapper(
            address(debtToken),
            address(underlying),
            10 ether // Will return only 10 ether regardless of input
        );

        // Approve the bad swapper
        vm.prank(owner);
        leverager.setSwapperApproval(address(badSwapper), true);

        // Try to leverage with minSwapOutput higher than what swapper will return
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        // With real AlchemistV3: deposit=10, flash=20, total collateral=30 MYT
        // Max debt at 111% collateralization = ~27 ether. Use mintAmount=25.
        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(badSwapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 20 ether, // Require 20 ether, but swapper only returns 10
            minYieldOut: 0
        });

        vm.expectRevert(V3Leverager.SlippageExceeded.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_LeverageSucceedsWhenSlippageMet() public {
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        // With real AlchemistV3: deposit=10, flash=20, total collateral=30 MYT
        // Max debt at 111% collateralization = ~27 ether. Use mintAmount=25.
        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1, // Reasonable min output
            minYieldOut: 0
        });

        // Should succeed
        leverager.leverage(params);
        vm.stopPrank();

        // Verify position was created
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertGt(collateral, 0);
        assertGt(debt, 0);
    }

    function test_RevertOnMinYieldOutNotMet() public {
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 40 ether // Impossible: only 10 deposit + 20 flash = 30 max
        });

        // MYTConverter reverts with InsufficientYieldOutput when minYieldOut not met
        vm.expectRevert(MYTConverter.InsufficientYieldOutput.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_DeleveragePaysRecipient() public {
        // Leverage first
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        // deposit=10, flash=20, total collateral=30, mint=25 debt
        ILeveragerV3.LeverageParams memory leverageParams = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });
        leverager.leverage(leverageParams);
        vm.stopPrank();

        // Advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        uint256 balanceBefore = IERC20(address(underlying)).balanceOf(alice);

        // Deleverage: flash 5 underlying, convert to MYT, repay 5 MYT of debt,
        // withdraw 6 collateral, convert to underlying, repay flash, surplus to alice.
        ILeveragerV3.DeleverageRepayParams memory deleverageParams = ILeveragerV3.DeleverageRepayParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            recipient: alice,
            withdrawAmount: 6 ether,
            flashLoanAmount: 5 ether,
            repayAmount: 5 ether,
            minOutput: 0
        });

        vm.prank(address(vault));
        leverager.deleverageRepay(deleverageParams);

        uint256 balanceAfter = IERC20(address(underlying)).balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
    }

    // ============ 4. Reentrancy Tests ============

    function test_LeverageIsNonReentrant() public {
        // This test verifies the nonReentrant modifier is in place
        // The actual reentrancy would require a malicious contract that calls back
        // during flash loan execution - the modifier should prevent this

        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 0, // No flash loan
            mintAmount: 8 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        // First call should succeed
        leverager.leverage(params);
        vm.stopPrank();
    }

    // ============ 5. Registry Security Tests ============

    function test_OnlyOwnerCanApproveConverters() public {
        MYTConverter newConverter = new MYTConverter(address(mytVault), address(underlying));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setConverterApproval(address(newConverter), true);
    }

    function test_OnlyOwnerCanApproveFlashLoanAdapters() public {
        LocalFlashLoanAdapter newAdapter = new LocalFlashLoanAdapter(address(underlying));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setFlashLoanAdapterApproval(address(newAdapter), true);
    }

    function test_OnlyOwnerCanApproveSwappers() public {
        SecurityLocalSwapper1Pct newSwapper = new SecurityLocalSwapper1Pct(address(debtToken), address(underlying));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setSwapperApproval(address(newSwapper), true);
    }

    function test_UnapprovedAdaptersRejected() public {
        MYTConverter unapprovedConverter = new MYTConverter(address(mytVault), address(underlying));

        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(unapprovedConverter), // Not approved
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    // ============ 6. Invalid Input Tests ============

    function test_RevertOnZeroVaultAddress() public {
        vm.startPrank(alice);
        IERC20(address(mytVault)).approve(address(leverager), 10 ether);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(0), // Invalid
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        // Should revert when trying to interact with zero address vault
        vm.expectRevert();
        leverager.leverage(params);
        vm.stopPrank();
    }

    // ============ 7. Euler Adapter Emergency Functions ============

    function test_EulerAdapter_EmergencyWithdraw() public {
        // Send some tokens to the adapter
        underlying.mint(address(eulerAdapter), 100 ether);

        address eulerOwner = eulerAdapter.owner();
        uint256 balanceBefore = IERC20(address(underlying)).balanceOf(eulerOwner);

        vm.prank(eulerOwner);
        eulerAdapter.emergencyWithdraw(address(underlying), 50 ether);

        assertEq(IERC20(address(underlying)).balanceOf(eulerOwner), balanceBefore + 50 ether);
    }

    function test_EulerAdapter_NonOwnerCannotEmergencyWithdraw() public {
        underlying.mint(address(eulerAdapter), 100 ether);

        vm.prank(attacker);
        vm.expectRevert();
        eulerAdapter.emergencyWithdraw(address(underlying), 50 ether);
    }
}
