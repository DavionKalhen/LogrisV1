// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./LocalAlchemistV3Base.t.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/converters/MYTConverter.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/ILeveragedVaultCallback.sol";
import {IFlashLoanAdapter} from "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import {IFlashLoanCallback} from "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import {IAlchemistV3} from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import {IAlchemistV3Position} from "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// ============ Lightweight Mocks for Modular Tests ============

/// @dev MockVault that interacts with a real AlchemistV3 via ILeveragedVaultCallback.
///      Exposes getYieldToken(), getUnderlyingToken(), and alchemist() so V3Leverager
///      can validate converter tokens and read the debt token.
contract ModularMockVault is ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    address public alchemistAddr;
    uint256 public vaultPositionId;
    address public leverager;
    address public underlyingToken;
    address public yieldToken;
    bool private positionCreated;

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    constructor(address _alchemist, address _leverager, address _underlyingToken, address _yieldToken) {
        alchemistAddr = _alchemist;
        leverager = _leverager;
        underlyingToken = _underlyingToken;
        yieldToken = _yieldToken;
    }

    /// @dev Returns the alchemist as IAlchemistV3 (needed by V3Leverager._getDebtToken)
    function alchemist() external view returns (IAlchemistV3) {
        return IAlchemistV3(alchemistAddr);
    }

    function getYieldToken() external view returns (address) {
        return yieldToken;
    }

    function getUnderlyingToken() external view returns (address) {
        return underlyingToken;
    }

    function vaultDepositYieldTokens(uint256 amount) external override onlyLeverager returns (uint256) {
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(alchemistAddr, amount);

        if (!positionCreated) {
            IAlchemistV3(alchemistAddr).deposit(amount, address(this), 0);
            // Get the position ID from the NFT
            address nftAddr = IAlchemistV3(alchemistAddr).alchemistPositionNFT();
            vaultPositionId = IAlchemistV3Position(nftAddr).tokenOfOwnerByIndex(address(this), 0);
            positionCreated = true;
        } else {
            IAlchemistV3(alchemistAddr).deposit(amount, address(this), vaultPositionId);
        }
        return amount;
    }

    function vaultMintDebtTokens(uint256 amount, address recipient) external override onlyLeverager {
        IAlchemistV3(alchemistAddr).mint(vaultPositionId, amount, recipient);
    }

    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external override onlyLeverager returns (uint256) {
        return IAlchemistV3(alchemistAddr).withdraw(amount, recipient, vaultPositionId);
    }

    function vaultRepayWithYieldTokens(uint256 amount) external override onlyLeverager returns (uint256) {
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(alchemistAddr, amount);
        return IAlchemistV3(alchemistAddr).repay(amount, vaultPositionId);
    }

    function getVaultPositionId() external view override returns (uint256) {
        return vaultPositionId;
    }
}

/// @dev 1% fee swapper: debt -> underlying with 1% loss. Mints underlying (MockERC20WithMetadata).
contract ModularSwapper1Pct is ISwapper {
    using SafeERC20 for IERC20;

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
        MockERC20WithMetadata(underlyingToken).mint(recipient, output);
        return output;
    }

    function swapUnderlyingToDebt(uint256, uint256, address, bytes calldata) external pure override returns (uint256) {
        return 0;
    }

    function previewSwapDebtToUnderlying(uint256 d) external pure override returns (uint256, uint256) {
        return (d * 99 / 100, d * 95 / 100);
    }

    function previewSwapUnderlyingToDebt(uint256 u) external pure override returns (uint256, uint256) {
        return (u * 99 / 100, u * 95 / 100);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 0.99e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 0.99e18; }
    function getSwapFee() external pure override returns (uint256) { return 100; }
    function getSlippageTolerance() external pure override returns (uint256) { return 0; }
    function isSupportedPair(address, address) external pure override returns (bool) { return true; }
}

/// @dev Flash loan adapter that mints underlying for the loan and charges zero fee.
contract ModularFlashLoanAdapter is IFlashLoanAdapter {
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
        MockERC20WithMetadata(_token).mint(address(this), amount);
        IERC20(_token).safeTransfer(recipient, amount);

        IFlashLoanCallback(recipient).onFlashLoanReceived(
            msg.sender,
            _token,
            amount,
            0,
            data
        );

        require(IERC20(_token).balanceOf(address(this)) >= amount, "Flash loan not repaid");
        emit FlashLoanExecuted(_token, amount, 0, recipient);
    }

    function getFlashLoanFee(address, uint256) external pure override returns (uint256) { return 0; }
    function isTokenSupported(address) external pure override returns (bool) { return true; }
    function maxFlashLoan(address) external pure override returns (uint256) { return type(uint256).max; }
    function getProvider() external view override returns (address) { return address(this); }
}

// ============ Test Contract ============

contract V3LeveragerModularTest is LocalAlchemistV3Base {
    V3Leverager public leverager;

    MYTConverter public converter;
    ModularSwapper1Pct public swapper;
    ModularFlashLoanAdapter public flashLoanAdapter;
    ModularMockVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function _leverageFromVault(ILeveragerV3.LeverageParams memory params, address funder) internal {
        if (params.depositAmount > 0) {
            vm.prank(funder);
            IERC20(address(mytVault)).transfer(params.vault, params.depositAmount);
            vm.prank(params.vault);
            IERC20(address(mytVault)).approve(address(leverager), params.depositAmount);
        }
        vm.prank(params.vault);
        leverager.leverage(params);
    }

    function setUp() public {
        _deployLocalAlchemistV3();

        // Deploy adapters
        converter = new MYTConverter(address(mytVault), address(underlying));
        swapper = new ModularSwapper1Pct(address(debtToken), address(underlying));
        flashLoanAdapter = new ModularFlashLoanAdapter(address(underlying));

        // Deploy leverager
        vm.prank(owner);
        leverager = new V3Leverager(owner);

        // Deploy mock vault wired to real AlchemistV3
        vault = new ModularMockVault(
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

        // Fund users with MYT (yield tokens)
        _fundWithMYT(alice, 100 ether);
        _fundWithMYT(bob, 100 ether);
    }

    // ============ Registry Tests ============

    function test_OwnerCanApproveConverter() public {
        MYTConverter newConverter = new MYTConverter(address(mytVault), address(underlying));

        assertFalse(leverager.isApprovedConverter(address(newConverter)));

        vm.prank(owner);
        leverager.setConverterApproval(address(newConverter), true);

        assertTrue(leverager.isApprovedConverter(address(newConverter)));
    }

    function test_OwnerCanRevokeConverter() public {
        assertTrue(leverager.isApprovedConverter(address(converter)));

        vm.prank(owner);
        leverager.setConverterApproval(address(converter), false);

        assertFalse(leverager.isApprovedConverter(address(converter)));
    }

    function test_NonOwnerCannotApproveConverter() public {
        MYTConverter newConverter = new MYTConverter(address(mytVault), address(underlying));

        vm.prank(alice);
        vm.expectRevert();
        leverager.setConverterApproval(address(newConverter), true);
    }

    function test_OwnerCanApproveFlashLoanAdapter() public {
        ModularFlashLoanAdapter newAdapter = new ModularFlashLoanAdapter(address(underlying));

        assertFalse(leverager.isApprovedFlashLoanAdapter(address(newAdapter)));

        vm.prank(owner);
        leverager.setFlashLoanAdapterApproval(address(newAdapter), true);

        assertTrue(leverager.isApprovedFlashLoanAdapter(address(newAdapter)));
    }

    function test_OwnerCanApproveSwapper() public {
        ModularSwapper1Pct newSwapper = new ModularSwapper1Pct(address(debtToken), address(underlying));

        assertFalse(leverager.isApprovedSwapper(address(newSwapper)));

        vm.prank(owner);
        leverager.setSwapperApproval(address(newSwapper), true);

        assertTrue(leverager.isApprovedSwapper(address(newSwapper)));
    }

    function test_BatchApprove() public {
        MYTConverter newConverter = new MYTConverter(address(mytVault), address(underlying));
        ModularFlashLoanAdapter newAdapter = new ModularFlashLoanAdapter(address(underlying));
        ModularSwapper1Pct newSwapper = new ModularSwapper1Pct(address(debtToken), address(underlying));

        address[] memory converters = new address[](1);
        converters[0] = address(newConverter);

        address[] memory adapters = new address[](1);
        adapters[0] = address(newAdapter);

        address[] memory swappers = new address[](1);
        swappers[0] = address(newSwapper);

        vm.prank(owner);
        leverager.batchApprove(converters, adapters, swappers);

        assertTrue(leverager.isApprovedConverter(address(newConverter)));
        assertTrue(leverager.isApprovedFlashLoanAdapter(address(newAdapter)));
        assertTrue(leverager.isApprovedSwapper(address(newSwapper)));
    }

    // ============ Leverage Tests ============

    function test_LeverageWithApprovedAdapters() public {
        uint256 depositAmount = 10 ether;
        uint256 flashLoanAmount = 20 ether;
        uint256 mintAmount = 25 ether;

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: depositAmount,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        _leverageFromVault(params, alice);

        // Verify position state via real AlchemistV3
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());

        // Total collateral = deposit (10 MYT) + flash loan converted to MYT (20 underlying -> ~20 MYT)
        assertEq(collateral, depositAmount + flashLoanAmount);
        assertEq(debt, mintAmount);
    }

    function test_DirectCallerReverts_Unauthorized() public {
        uint256 depositAmount = 10 ether;
        uint256 flashLoanAmount = 20 ether;
        uint256 mintAmount = 25 ether;

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: depositAmount,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.prank(alice);
        vm.expectRevert(V3Leverager.UnauthorizedCaller.selector);
        leverager.leverage(params);
    }

    function test_VaultRoutedLeverage_SurplusAccruesToVault() public {
        uint256 depositAmount = 10 ether;
        uint256 flashLoanAmount = 20 ether;
        uint256 mintAmount = 25 ether;

        uint256 aliceUnderlyingBefore = IERC20(address(underlying)).balanceOf(alice);
        uint256 vaultUnderlyingBefore = IERC20(address(underlying)).balanceOf(address(vault));

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: depositAmount,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        _leverageFromVault(params, alice);

        uint256 aliceUnderlyingAfter = IERC20(address(underlying)).balanceOf(alice);
        uint256 vaultUnderlyingAfter = IERC20(address(underlying)).balanceOf(address(vault));

        // Swapper returns 99% of mintAmount (24.75), flash repayment is 20, surplus is 4.75.
        assertEq(aliceUnderlyingAfter - aliceUnderlyingBefore, 0, "EOA caller should not receive leverage surplus");
        assertEq(vaultUnderlyingAfter - vaultUnderlyingBefore, 4.75 ether, "Surplus should remain in vault");
    }

    function test_LeverageRevertsWithUnapprovedConverter() public {
        MYTConverter unapprovedConverter = new MYTConverter(address(mytVault), address(underlying));

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(unapprovedConverter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.prank(address(vault));
        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.leverage(params);
    }

    function test_LeverageRevertsWithUnapprovedFlashLoanAdapter() public {
        ModularFlashLoanAdapter unapprovedAdapter = new ModularFlashLoanAdapter(address(underlying));

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(unapprovedAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.prank(address(vault));
        vm.expectRevert(V3Leverager.UnapprovedFlashLoanAdapter.selector);
        leverager.leverage(params);
    }

    function test_LeverageRevertsWithUnapprovedSwapper() public {
        ModularSwapper1Pct unapprovedSwapper = new ModularSwapper1Pct(address(debtToken), address(underlying));

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(unapprovedSwapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.prank(address(vault));
        vm.expectRevert(V3Leverager.UnapprovedSwapper.selector);
        leverager.leverage(params);
    }

    function test_LeverageWithZeroDeposit() public {
        // Zero-deposit leverage: depositAmount=0 but flash loan adds collateral.
        // With 111% collateralization and 1% swap fee, a fresh position can't self-repay
        // because maxDebt * 0.99 < flashLoanAmount. Seed the vault's position with existing
        // collateral so the combined position supports the required mint.
        //
        // 1. Seed: deposit 30 MYT directly into vault's alchemist position (via normal leverage)
        ILeveragerV3.LeverageParams memory seedParams = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 30 ether,
            flashLoanAmount: 0,
            mintAmount: 1, // minimal mint to satisfy leverager's unconditional mint call
            minSwapOutput: 0,
            minYieldOut: 0
        });
        _leverageFromVault(seedParams, alice);

        // Now do a zero-deposit leverage with flash loan against the existing position.
        // Existing collateral = 30, existing debt = 1.
        // flash = 20. After deposit: collateral = 50. maxDebt = 50/1.111 ≈ 45.
        // mint = 25. total debt = 26. swap output = 25 * 0.99 = 24.75 > 20 flash. Works!
        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 0,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        _leverageFromVault(params, alice);

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 50 ether); // 30 seed + 20 flash
        // Debt = 25 ether + seed mint (1 wei). Rounding in AlchemistV3._sync may add 1 wei.
        assertApproxEqAbs(debt, 25 ether, 2); // 25 ether from second leverage + negligible seed
    }

    // ============ Deleverage Tests ============

    function test_DeleverageWithApprovedAdapters() public {
        // First leverage to create a position
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
        _leverageFromVault(leverageParams, alice);

        // Must advance block to avoid CannotRepayOnMintBlock
        vm.roll(block.number + 1);

        // Now deleverage: flash 12 underlying -> convert to ~12 MYT -> repay 12 MYT ->
        // withdraw 15 MYT -> convert 15 MYT -> ~15 underlying ->
        // repay flash loan (12) -> surplus 3 to user
        // Need repayAmount=12 so that remaining debt (13) * 1.111 < 30, leaving enough free to withdraw 15.
        ILeveragerV3.DeleverageRepayParams memory deleverageParams = ILeveragerV3.DeleverageRepayParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            recipient: alice,
            withdrawAmount: 15 ether,
            flashLoanAmount: 12 ether,
            repayAmount: 12 ether,
            minOutput: 1
        });

        vm.prank(address(vault));
        leverager.deleverageRepay(deleverageParams);

        // Position should be reduced
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 30 ether - 15 ether); // Withdrew 15
        assertEq(debt, 25 ether - 12 ether);        // 12 was repaid
    }

    function test_DeleverageRevertsWithUnapprovedConverter() public {
        MYTConverter unapprovedConverter = new MYTConverter(address(mytVault), address(underlying));

        ILeveragerV3.DeleverageRepayParams memory params = ILeveragerV3.DeleverageRepayParams({
            vault: address(vault),
            converter: address(unapprovedConverter),
            flashLoanAdapter: address(flashLoanAdapter),
            recipient: alice,
            withdrawAmount: 10 ether,
            flashLoanAmount: 10 ether,
            repayAmount: 10 ether,
            minOutput: 1
        });

        vm.prank(address(vault));
        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.deleverageRepay(params);
    }

    // ============ Multi-Vault Tests ============

    function test_SameLeveragerServesMultipleVaults() public {
        // Deploy second vault backed by same real AlchemistV3
        ModularMockVault vault2 = new ModularMockVault(
            address(alchemist),
            address(leverager),
            address(underlying),
            address(mytVault)
        );

        // Alice leverages vault 1
        ILeveragerV3.LeverageParams memory params1 = ILeveragerV3.LeverageParams({
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
        _leverageFromVault(params1, alice);

        // Bob leverages vault 2
        ILeveragerV3.LeverageParams memory params2 = ILeveragerV3.LeverageParams({
            vault: address(vault2),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 15 ether,
            flashLoanAmount: 30 ether,
            mintAmount: 40 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });
        _leverageFromVault(params2, bob);

        // Verify both vaults have independent positions
        (uint256 collateral1, uint256 debt1,) = alchemist.getCDP(vault.getVaultPositionId());
        (uint256 collateral2, uint256 debt2,) = alchemist.getCDP(vault2.getVaultPositionId());

        assertEq(collateral1, 30 ether);
        assertEq(debt1, 25 ether);
        assertEq(collateral2, 45 ether);
        assertEq(debt2, 40 ether);
    }

    // ============ Multiple Adapter Tests ============

    function test_SwitchBetweenAdapters() public {
        // Deploy alternative adapters
        ModularFlashLoanAdapter altFlashLoan = new ModularFlashLoanAdapter(address(underlying));
        ModularSwapper1Pct altSwapper = new ModularSwapper1Pct(address(debtToken), address(underlying));

        // Approve them
        vm.startPrank(owner);
        leverager.setFlashLoanAdapterApproval(address(altFlashLoan), true);
        leverager.setSwapperApproval(address(altSwapper), true);
        vm.stopPrank();

        // Use original adapters
        ILeveragerV3.LeverageParams memory params1 = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 5 ether,
            flashLoanAmount: 10 ether,
            mintAmount: 12 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });
        _leverageFromVault(params1, alice);

        // Use alternative adapters for second leverage
        ILeveragerV3.LeverageParams memory params2 = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(altFlashLoan),
            swapper: address(altSwapper),
            depositAmount: 5 ether,
            flashLoanAmount: 10 ether,
            mintAmount: 12 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });
        _leverageFromVault(params2, alice);

        // Both operations should have succeeded
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 30 ether); // 15 + 15
        assertEq(debt, 24 ether);       // 12 + 12
    }

    // ============ Events Tests ============

    function test_EmitsLeverageExecutedEvent() public {
        uint256 depositAmount = 10 ether;

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: depositAmount,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 0
        });

        vm.prank(alice);
        IERC20(address(mytVault)).transfer(address(vault), depositAmount);
        vm.prank(address(vault));
        IERC20(address(mytVault)).approve(address(leverager), depositAmount);

        vm.expectEmit(true, true, false, false);
        emit ILeveragerV3.LeverageExecuted(
            address(vault),
            address(vault),
            10 ether,
            20 ether,
            30 ether,
            25 ether
        );

        vm.prank(address(vault));
        leverager.leverage(params);
    }

    function test_EmitsConverterApprovalEvent() public {
        MYTConverter newConverter = new MYTConverter(address(mytVault), address(underlying));

        vm.expectEmit(true, false, false, true);
        emit ILeveragerV3.ConverterApprovalSet(address(newConverter), true);

        vm.prank(owner);
        leverager.setConverterApproval(address(newConverter), true);
    }
}
