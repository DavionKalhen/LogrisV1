// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/LeveragedVault.sol";
import "../src/interfaces/ILeveragedVaultFactory.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract DummyContract {}

contract LeveragedVaultFactoryTest is Test {
    LeveragedVaultFactory public factory;

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
        // Deploy factory
        factory = new LeveragedVaultFactory();

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

    // ===== ACCESS CONTROL TESTS =====

    function testOnlyOwnerCanCreate() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Yield token cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Underlying token cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Alchemist cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Leverager cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("WETH cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Default converter cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Default flash loan adapter cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Default swapper cannot be 0");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Underlying slippage basis points must be less than 10000");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
        vm.expectRevert("Debt slippage basis points must be less than 10000");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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

    function testVaultsInitiallyZero() public view {
        assertEq(factory.vaults(mockYieldToken), address(0), "No vault should exist initially");
    }

    function testRevertDuplicateYieldToken() public {
        factory.createVault(
            "Test Vault",
            "TVAULT",
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

        vm.expectRevert("Vault already exists for yield token");
        factory.createVault(
            "Test Vault 2",
            "TVAULT2",
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
        vm.expectRevert("Yield token must be a contract");
        factory.createVault(
            "Test Vault",
            "TVAULT",
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
}
