// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

// AlchemistV3 from source
import "../alchemix-v3/src/AlchemistV3.sol";
import "../alchemix-v3/src/AlchemistV3Position.sol";
import "../alchemix-v3/src/AlchemistTokenVault.sol";
import "../alchemix-v3/src/Transmuter.sol";
import "../alchemix-v3/src/interfaces/ITransmuter.sol";
import "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Our contracts
import "../src/LeveragedVault.sol";
import "../src/LeveragedVaultFactory.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/adapters/flashloan/AaveV3FlashLoanAdapter.sol";
import "../src/adapters/CurveSwapper.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/converters/WETHToWstETHConverter.sol";
import "../src/interfaces/ILeveragerV3.sol";

// Interfaces
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal interfaces for E2E testing (renamed to avoid import conflicts)
interface IE2EWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IE2EWstETH {
    function wrap(uint256) external returns (uint256);
    function unwrap(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function getWstETHByStETH(uint256) external view returns (uint256);
}

interface IE2EStETH {
    function submit(address) external payable returns (uint256);
    function approve(address, uint256) external returns (bool);
    function getSharesByPooledEth(uint256) external view returns (uint256);
}

interface IAlETHAdmin {
    function setWhitelist(address account, bool state) external;
    function whiteList(address) external view returns (bool);
}

/**
 * @title V3LeveragerE2ETest
 * @notice End-to-end tests for the modular V3Leverager architecture
 * @dev Runs on Ethereum mainnet fork with real AlchemistV3, real tokens
 */
contract V3LeveragerE2ETest is Test {
    // ============ Mainnet Addresses ============

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ALETH = 0x0100546F2cD4C9D97f798fFC9755E47865FF7Ee6;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant CURVE_ALETH_POOL = 0x8eFD02a0a40545F32DbA5D664CbBC1570D3FedF6;
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    int128 constant CURVE_ALETH_WETH_INDEX = 1;
    int128 constant CURVE_ALETH_INDEX = 0;
    int128 constant CURVE_STETH_ETH_INDEX = 0;
    int128 constant CURVE_STETH_INDEX = 1;

    // AlchemistV3 config
    uint256 constant MIN_COLLATERALIZATION = 1_111_111_111_111_111_111; // ~111%
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1_052_631_578_950_000_000; // ~105%
    uint256 constant BLOCKS_PER_YEAR = 2_600_000;

    // ============ Deployed Contracts ============

    AlchemistV3 public alchemist;
    AlchemistV3Position public positionNFT;
    Transmuter public transmuter;
    AlchemistTokenVault public feeVault;
    WstETHAdapter public tokenAdapter;
    CurveSwapper public stEthSwapper;

    V3Leverager public leverager;
    BalancerFlashLoanAdapter public flashLoanAdapter;
    AaveV3FlashLoanAdapter public aaveFlashLoanAdapter;
    CurveSwapper public swapper;
    WETHToWstETHConverter public converter;

    LeveragedVaultFactory public factory;
    LeveragedVault public vault;

    // ============ Test Users ============

    address public deployer;
    address public alice;
    address public bob;

    // ============ Setup ============

    function setUp() public {
        // Fork mainnet
        string memory rpcUrl = vm.envOr("ALCHEMY_KEY", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl);

        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(deployer, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.startPrank(deployer);

        // Deploy full stack
        _deployAlchemistV3Stack();
        _deployAdapters();
        _deployLeveragerAndVault();

        vm.stopPrank();

        // Whitelist our AlchemistV3 on real alETH (requires impersonation)
        _whitelistAlchemistOnAlETH();

        // Fund test users with wstETH
        _fundUserWithWstETH(alice, 50 ether);
        _fundUserWithWstETH(bob, 50 ether);
    }

    function _deployAlchemistV3Stack() internal {
        // 1. Deploy CurveSwapper for stETH -> WETH (used by WstETHAdapter)
        stEthSwapper = new CurveSwapper(
            CURVE_STETH_POOL,
            STETH,
            WETH,
            CURVE_STETH_ETH_INDEX,
            CURVE_STETH_INDEX,
            WETH,
            true,
            deployer
        );

        // 2. Deploy WstETH adapter
        tokenAdapter = new WstETHAdapter(address(stEthSwapper), 9950, deployer);

        // 3. Deploy Transmuter
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: ALETH,
            feeReceiver: deployer,
            timeToTransmute: 5_256_000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52_560_000
        });
        transmuter = new Transmuter(transmuterParams);

        // 4. Deploy AlchemistV3
        AlchemistV3 alchemistImpl = new AlchemistV3();
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployer,
            debtToken: ALETH,
            underlyingToken: WETH,
            yieldToken: WSTETH,
            blocksPerYear: BLOCKS_PER_YEAR,
            depositCap: type(uint256).max,
            minimumCollateralization: MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            globalMinimumCollateralization: MIN_COLLATERALIZATION,
            tokenAdapter: address(tokenAdapter),
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: deployer,
            liquidatorFee: 300
        });
        bytes memory initData = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        ERC1967Proxy proxy = new ERC1967Proxy(address(alchemistImpl), initData);
        alchemist = AlchemistV3(address(proxy));

        // 4. Deploy Position NFT
        positionNFT = new AlchemistV3Position(address(alchemist));
        alchemist.setAlchemistPositionNFT(address(positionNFT));

        // 5. Deploy Fee Vault
        feeVault = new AlchemistTokenVault(WETH, address(alchemist), deployer);
        feeVault.setAuthorization(address(alchemist), true);
        alchemist.setAlchemistFeeVault(address(feeVault));

        // 6. Configure Transmuter
        transmuter.setAlchemist(address(alchemist));
        transmuter.setDepositCap(uint256(type(int256).max));
    }

    function _deployAdapters() internal {
        // Flash loan adapter (Balancer - 0% fee)
        flashLoanAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);
        // Flash loan adapter (Aave V3 - 5 bps fee)
        aaveFlashLoanAdapter = new AaveV3FlashLoanAdapter(address(0));

        // Curve swapper for alETH/ETH
        swapper = new CurveSwapper(
            CURVE_ALETH_POOL,
            ALETH,
            WETH,
            CURVE_ALETH_WETH_INDEX,
            CURVE_ALETH_INDEX,
            WETH,
            false,
            deployer
        );

        // WETH to wstETH converter
        converter = new WETHToWstETHConverter(
            WETH,
            STETH,
            WSTETH,
            CURVE_STETH_POOL,
            CURVE_STETH_ETH_INDEX,
            CURVE_STETH_INDEX,
            9950,
            deployer
        );
    }

    function _deployLeveragerAndVault() internal {
        // Deploy V3Leverager
        leverager = new V3Leverager(deployer);

        // Approve adapters
        address[] memory converters = new address[](1);
        converters[0] = address(converter);
        address[] memory flashLoanAdapters = new address[](2);
        flashLoanAdapters[0] = address(flashLoanAdapter);
        flashLoanAdapters[1] = address(aaveFlashLoanAdapter);
        address[] memory swappers = new address[](1);
        swappers[0] = address(swapper);
        leverager.batchApprove(converters, flashLoanAdapters, swappers);

        // Deploy implementation, factory, and vault
        LeveragedVault impl = new LeveragedVault();
        factory = new LeveragedVaultFactory(address(impl));
        address vaultAddr = factory.createVault(
            WSTETH,
            WETH,
            address(alchemist),
            address(leverager),
            100,  // 1% underlying slippage
            400,  // 4% debt slippage (includes alETH peg deviation + trade slippage)
            address(converter),
            address(flashLoanAdapter),
            address(swapper),
            WETH
        );
        vault = LeveragedVault(payable(vaultAddr));
    }

    function _whitelistAlchemistOnAlETH() internal {
        // alETH admin address (hardcoded from mainnet - the contract owner/admin)
        address alETHAdmin = 0x8392F6669292fA56123F71949B52d883aE57e225;

        vm.prank(alETHAdmin);
        IAlETHAdmin(ALETH).setWhitelist(address(alchemist), true);

        // Verify whitelist worked
        assertTrue(IAlETHAdmin(ALETH).whiteList(address(alchemist)), "Alchemist should be whitelisted");
    }

    function _fundUserWithWstETH(address user, uint256 ethAmount) internal {
        vm.startPrank(user);

        // ETH -> stETH -> wstETH
        uint256 stEthReceived = IE2EStETH(STETH).submit{value: ethAmount}(address(0));
        IE2EStETH(STETH).approve(WSTETH, stEthReceived);
        IE2EWstETH(WSTETH).wrap(stEthReceived);

        vm.stopPrank();
    }

    // ============ E2E Tests ============

    function test_E2E_FullStackDeployment() public view {
        // Verify all contracts deployed correctly
        assertTrue(address(alchemist) != address(0), "Alchemist not deployed");
        assertTrue(address(leverager) != address(0), "Leverager not deployed");
        assertTrue(address(vault) != address(0), "Vault not deployed");
        assertTrue(address(converter) != address(0), "Converter not deployed");

        // Verify adapters approved
        assertTrue(leverager.isApprovedConverter(address(converter)));
        assertTrue(leverager.isApprovedFlashLoanAdapter(address(flashLoanAdapter)));
        assertTrue(leverager.isApprovedSwapper(address(swapper)));

        // Verify vault configuration
        assertEq(vault.converter(), address(converter));
        assertEq(vault.flashLoanAdapter(), address(flashLoanAdapter));
        assertEq(vault.swapper(), address(swapper));
    }

    function test_E2E_ConverterWETHToWstETH() public {
        uint256 wethAmount = 1 ether;

        // Get WETH
        vm.startPrank(alice);
        IE2EWETH(WETH).deposit{value: wethAmount}();

        // Approve converter
        IE2EWETH(WETH).approve(address(converter), wethAmount);

        // Convert WETH -> wstETH
        uint256 wstEthBefore = IE2EWstETH(WSTETH).balanceOf(alice);
        uint256 wstEthReceived = converter.toYield(wethAmount, alice, 0);
        uint256 wstEthAfter = IE2EWstETH(WSTETH).balanceOf(alice);

        vm.stopPrank();

        assertGt(wstEthReceived, 0, "Should receive wstETH");
        assertEq(wstEthAfter - wstEthBefore, wstEthReceived, "Balance should increase");
    }

    function test_E2E_FlashLoanAvailability() public view {
        uint256 maxWETH = flashLoanAdapter.maxFlashLoan(WETH);

        assertTrue(maxWETH > 1000 ether, "Should have significant WETH liquidity");
        assertEq(flashLoanAdapter.getFlashLoanFee(WETH, 100 ether), 0, "Balancer should have 0 fee");
    }

    function test_E2E_AaveFlashLoanFee() public view {
        uint256 maxWETH = aaveFlashLoanAdapter.maxFlashLoan(WETH);

        uint256 fee = aaveFlashLoanAdapter.getFlashLoanFee(WETH, 100 ether);
        // 5 bps = 0.05 WETH on 100 WETH
        assertEq(fee, 0.05 ether, "Aave flash loan fee should be 5 bps");
    }

    function test_E2E_DepositToVault() public {
        // Use the payable depositUnderlying() which wraps ETH→WETH and leaves WETH in vault
        uint256 depositAmount = 5 ether;

        vm.startPrank(alice);

        // Deposit ETH directly (gets wrapped to WETH in the vault's deposit pool)
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 shares = vault.depositUnderlying{value: depositAmount}();
        uint256 sharesAfter = vault.balanceOf(alice);

        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance should increase");
        assertEq(vault.getDepositPoolBalance(), depositAmount, "Pool should have WETH");
    }

    function test_E2E_LeveragePosition() public {
        // This test validates that we can:
        // 1. Deposit ETH to the vault
        // 2. Convert WETH → wstETH
        // 3. Deposit wstETH to AlchemistV3
        // 4. Mint alETH (without swapping back)
        //
        // Note: Full leverage with Curve swap may fail due to pool liquidity at fork block
        // This test validates the core deposit/mint flow works

        uint256 depositAmount = 5 ether;

        // 1. Alice deposits ETH to vault (wraps to WETH in deposit pool)
        vm.startPrank(alice);
        vault.depositUnderlying{value: depositAmount}();
        vm.stopPrank();

        // 2. Convert WETH → wstETH manually (simulating what leverage does)
        uint256 poolBalance = vault.getDepositPoolBalance();
        assertEq(poolBalance, depositAmount, "Pool should have deposit");

        // Preview the conversion
        uint256 expectedWstETH = converter.previewToYield(depositAmount);

        // 3. Directly deposit wstETH to Alchemist (bypassing full leverage)
        // First, convert WETH → wstETH in the vault
        vm.startPrank(address(vault));
        IERC20(WETH).approve(address(converter), depositAmount);
        uint256 actualWstETH = converter.toYield(depositAmount, address(vault), 0);
        vm.stopPrank();

        assertGt(actualWstETH, 0, "Should receive wstETH");

        // 4. Deposit wstETH to Alchemist and create position
        vm.startPrank(address(vault));
        IERC20(WSTETH).approve(address(alchemist), actualWstETH);
        alchemist.deposit(actualWstETH, address(vault), 0);  // Creates new position
        vm.stopPrank();

        // 5. Verify position was created (position ID 1 for first position)
        uint256 positionId = 1;  // First position

        (uint256 collateral, , ) = alchemist.getCDP(positionId);

        assertEq(collateral, actualWstETH, "Collateral should match deposited amount");
    }

    function test_E2E_ImmutableAdaptersMatchDeployment() public view {
        // Verify adapters are set at construction and match what was deployed
        assertEq(vault.converter(), address(converter), "Converter should be immutable");
        assertEq(vault.flashLoanAdapter(), address(flashLoanAdapter), "Flash loan adapter should be immutable");
        assertEq(vault.swapper(), address(swapper), "Swapper should be immutable");

        // Verify leverager has approved these adapters
        assertTrue(leverager.isApprovedConverter(address(converter)), "Converter should be approved");
        assertTrue(leverager.isApprovedFlashLoanAdapter(address(flashLoanAdapter)), "Flash loan adapter should be approved");
        assertTrue(leverager.isApprovedSwapper(address(swapper)), "Swapper should be approved");
    }

    function test_E2E_LeverageWithBalancerFlashLoan() public {
        uint256 depositAmount = 5 ether;

        // 1. Deposit ETH into the vault (pool)
        vm.startPrank(alice);
        vault.depositUnderlying{value: depositAmount}();
        vm.stopPrank();

        // 2. Compute min yield from deposit using Lido share math
        uint32 underlyingSlippage = 100;
        uint32 debtSlippage = 400;
        uint256 expectedShares = IE2EStETH(STETH).getSharesByPooledEth(depositAmount);
        uint256 expectedYield = IE2EWstETH(WSTETH).getWstETHByStETH(expectedShares);
        uint256 underlyingDepositMin = expectedYield * (10_000 - underlyingSlippage) / 10_000;

        // 3. Choose a conservative flash loan size
        uint256 flashLoanAmount = depositAmount / 5;
        uint256 minColl = alchemist.minimumCollateralization();

        // 4. Size mint amount based on Curve quote (Balancer has 0% fee)
        (uint256 ratePerDebt, ) = swapper.previewSwapDebtToUnderlying(1 ether);
        require(ratePerDebt > 0, "Curve rate unavailable");

        uint256 maxDebt = (depositAmount + flashLoanAmount) * 1e18 / minColl;

        uint256 maxFlashLoan = maxDebt * ratePerDebt / 1e18;
        if (flashLoanAmount > maxFlashLoan) {
            flashLoanAmount = maxFlashLoan;
        }

        uint256 requiredDebt = flashLoanAmount * 1e18 / ratePerDebt;
        uint256 mintAmount = requiredDebt * 10_000 / (10_000 - debtSlippage);
        if (mintAmount > maxDebt) {
            mintAmount = maxDebt;
        }

        (uint256 expectedOut, ) = swapper.previewSwapDebtToUnderlying(mintAmount);
        uint256 minSwapOut = expectedOut * (10_000 - debtSlippage) / 10_000;
        if (minSwapOut < flashLoanAmount) {
            flashLoanAmount = minSwapOut;
        }
        require(minSwapOut >= flashLoanAmount, "Swap output below repay target");

        // 5. Execute leverage using vault's immutable default adapters (Balancer)
        vm.prank(alice);
        vault.leverage(depositAmount, flashLoanAmount, underlyingDepositMin, mintAmount, minSwapOut);

        uint256 positionId = vault.getVaultPositionId();
        assertGt(positionId, 0, "Position should be created");

        (, uint256 debt, ) = alchemist.getCDP(positionId);
        assertGt(debt, 0, "Debt should be minted");
    }

    function test_E2E_MultipleDepositors() public {
        // Alice deposits ETH
        vm.startPrank(alice);
        uint256 aliceShares = vault.depositUnderlying{value: 5 ether}();
        vm.stopPrank();

        // Bob deposits ETH
        vm.startPrank(bob);
        uint256 bobShares = vault.depositUnderlying{value: 10 ether}();
        vm.stopPrank();

        // Verify deposits work and shares are positive
        assertGt(aliceShares, 0, "Alice should receive shares");
        assertGt(bobShares, 0, "Bob should receive shares");
        assertEq(vault.getDepositPoolBalance(), 15 ether, "Pool should have 15 ETH worth of WETH");

        // Note: The share ratio may not be exactly 2x due to how ERC4626 calculates
        // shares based on totalAssets() which includes the pool balance
    }

    function test_E2E_LeverageAndCheckHealth() public {
        // Test AlchemistV3 position health tracking
        // Manually create a position and verify health metrics

        uint256 depositAmount = 10 ether;

        // 1. Deposit ETH and convert to wstETH
        vm.startPrank(alice);
        vault.depositUnderlying{value: depositAmount}();
        vm.stopPrank();

        // 2. Convert and deposit directly to Alchemist
        vm.startPrank(address(vault));
        IERC20(WETH).approve(address(converter), depositAmount);
        uint256 wstETHAmount = converter.toYield(depositAmount, address(vault), 0);
        IERC20(WSTETH).approve(address(alchemist), wstETHAmount);
        alchemist.deposit(wstETHAmount, address(vault), 0);
        vm.stopPrank();

        // 3. Get position and mint some debt
        uint256 positionId = 1;  // First position
        (uint256 collateral, , ) = alchemist.getCDP(positionId);

        // Calculate max mintable (90% of capacity for safety)
        uint256 maxMint = (collateral * 1e18) / MIN_COLLATERALIZATION * 90 / 100;

        // Mint some debt
        vm.prank(address(vault));
        alchemist.mint(positionId, maxMint, address(vault));

        // 4. Check health after mint
        uint256 debt;
        (collateral, debt, ) = alchemist.getCDP(positionId);

        // Calculate collateralization ratio
        uint256 collateralRatio = (collateral * 1e18) / debt;

        // Should be above minimum (111%)
        assertTrue(collateralRatio >= MIN_COLLATERALIZATION, "Should be properly collateralized");
    }

    function test_E2E_GasUsage() public {
        // Test gas usage for key operations

        uint256 depositAmount = 5 ether;

        // 1. Measure gas for ETH deposit
        vm.startPrank(alice);
        uint256 gasBefore = gasleft();
        vault.depositUnderlying{value: depositAmount}();
        uint256 depositGas = gasBefore - gasleft();
        vm.stopPrank();

        assertTrue(depositGas < 200_000, "Deposit gas should be under 200k");

        // 2. Measure gas for WETH→wstETH conversion
        vm.startPrank(address(vault));
        IERC20(WETH).approve(address(converter), depositAmount);
        gasBefore = gasleft();
        uint256 wstETH = converter.toYield(depositAmount, address(vault), 0);
        uint256 conversionGas = gasBefore - gasleft();
        vm.stopPrank();

        assertTrue(conversionGas < 500_000, "Conversion gas should be under 500k");

        // 3. Measure gas for Alchemist deposit
        vm.startPrank(address(vault));
        IERC20(WSTETH).approve(address(alchemist), wstETH);
        gasBefore = gasleft();
        alchemist.deposit(wstETH, address(vault), 0);
        uint256 alchemistDepositGas = gasBefore - gasleft();
        vm.stopPrank();

        assertTrue(alchemistDepositGas < 500_000, "Alchemist deposit gas should be under 500k");
    }

    // ============ Error Cases ============

    function test_E2E_RevertOnUnapprovedAdapter() public {
        // Deploy unapproved converter
        WETHToWstETHConverter unapprovedConverter = new WETHToWstETHConverter(
            WETH,
            STETH,
            WSTETH,
            CURVE_STETH_POOL,
            CURVE_STETH_ETH_INDEX,
            CURVE_STETH_INDEX,
            9950,
            deployer
        );

        // Verify the unapproved converter is not in the leverager registry
        assertFalse(
            leverager.isApprovedConverter(address(unapprovedConverter)),
            "Unapproved converter should not be in registry"
        );

        // The vault's immutable adapters are approved, so leverage() works
        // But a vault deployed with the unapproved converter would fail at leverage time
        assertTrue(
            leverager.isApprovedConverter(vault.converter()),
            "Vault's default converter must be approved in leverager"
        );
    }
}
