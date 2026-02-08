// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/LeveragedVault.sol";
import "../src/interfaces/ILeveragedVaultFactory.sol";
contract DummyContract {
    function symbol() external pure returns (string memory) { return "MOCK"; }
}

contract LeveragedVaultFactoryTest is Test {
    LeveragedVaultFactory public factory;
    LeveragedVault public impl;

    address public owner = address(this);
    address public nonOwner = address(0x100);

    // Mock addresses for validation tests
    address public mockAlchemist;
    address public mockYieldToken;
    address public mockUnderlyingToken;
    address public mockLeverager;
    address public mockConverter;
    address public mockFlashLoanAdapter;
    address public mockSwapper;
    address public mockWeth;


    function setUp() public {
        // Deploy implementation and factory
        impl = new LeveragedVault();
        factory = new LeveragedVaultFactory(address(impl));

        // Deploy dummy contracts to satisfy contract checks
        mockAlchemist = address(new DummyContract());
        mockYieldToken = address(new DummyContract());
        mockUnderlyingToken = address(new DummyContract());
        mockLeverager = address(new DummyContract());
        mockConverter = address(new DummyContract());
        mockFlashLoanAdapter = address(new DummyContract());
        mockSwapper = address(new DummyContract());
        mockWeth = address(new DummyContract());
    }

    // ===== OWNERSHIP TESTS =====

    function testOwnerIsDeployer() public view {
        assertEq(factory.owner(), owner, "Owner should be deployer");
    }

    function testOwnerCanTransferOwnership() public {
        factory.transferOwnership(nonOwner);
        assertEq(factory.owner(), nonOwner, "Ownership should transfer");
    }

    function testNonOwnerCannotTransferOwnership() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.transferOwnership(address(0x999));
    }

    // ===== IMPLEMENTATION TESTS =====

    function testImplementationIsSet() public view {
        assertEq(factory.IMPLEMENTATION(), address(impl), "Implementation should be set");
    }

    // ===== ACCESS CONTROL TESTS =====

    function testOnlyOwnerCanCreate() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    // ===== VALIDATION TESTS =====

    function testRevertZeroYieldToken() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            address(0),
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroUnderlyingToken() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            address(0),
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroAlchemist() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            address(0),
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroLeverager() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            address(0),
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroWeth() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            address(0)
        );
    }

    function testRevertZeroDefaultConverter() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            address(0),
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroDefaultFlashLoanAdapter() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            address(0),
            mockSwapper,
            mockWeth
        );
    }

    function testRevertZeroDefaultSwapper() public {
        vm.expectRevert(LeveragedVaultFactory.ZeroAddress.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            address(0),
            mockWeth
        );
    }

    // ===== SLIPPAGE VALIDATION TESTS =====

    function testRevertExcessiveUnderlyingSlippage() public {
        vm.expectRevert(LeveragedVaultFactory.SlippageTooHigh.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            10000,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertExcessiveDebtSlippage() public {
        vm.expectRevert(LeveragedVaultFactory.SlippageTooHigh.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            10000,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    // ===== VAULT TRACKING TESTS =====

    function testVaultsInitiallyEmpty() public view {
        assertEq(factory.getVaultsByYieldToken(mockYieldToken).length, 0, "No vault should exist initially");
    }

    function testGetVaultsByYieldTokenReturnsCreatedVault() public {
        address vault = factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );

        address[] memory vaults = factory.getVaultsByYieldToken(mockYieldToken);
        assertEq(vaults.length, 1, "Should have one vault");
        assertEq(vaults[0], vault, "Should be the created vault");

        LeveragedVault lv = LeveragedVault(payable(vault));
        assertEq(lv.name(), "Logris Leveraged MOCK", "Name should derive from underlying symbol");
        assertEq(lv.symbol(), "lvMOCK", "Symbol should derive from underlying symbol");
    }

    function testRevertDuplicateYieldToken() public {
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );

        vm.expectRevert(LeveragedVaultFactory.VaultAlreadyExists.selector);
        factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    function testRevertNonContractYieldToken() public {
        vm.expectRevert(LeveragedVaultFactory.NotAContract.selector);
        factory.createVault(
            address(0xDEAD),
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );
    }

    // ===== INITIALIZATION PROTECTION TESTS =====

    function testImplementationCannotBeInitialized() public {
        vm.expectRevert();
        impl.initialize(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth,
            address(this)
        );
    }

    function testCloneCannotBeDoubleInitialized() public {
        address vault = factory.createVault(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth
        );

        vm.expectRevert();
        LeveragedVault(payable(vault)).initialize(
            mockYieldToken,
            mockUnderlyingToken,
            mockAlchemist,
            mockLeverager,
            100,
            300,
            mockConverter,
            mockFlashLoanAdapter,
            mockSwapper,
            mockWeth,
            address(this)
        );
    }
}
