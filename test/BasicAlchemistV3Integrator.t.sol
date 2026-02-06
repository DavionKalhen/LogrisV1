// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/forge-std/src/Test.sol";
import "../src/BasicAlchemistV3Integrator.sol";
import "../src/base/AlchemistV3Base.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/forge-std/src/console.sol";
import "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Alchemix v3 imports
import "alchemix-v3/src/AlchemistV3.sol";
import "alchemix-v3/src/AlchemistV3Position.sol";
import "alchemix-v3/src/test/mocks/TestERC20.sol";
import "alchemix-v3/src/test/mocks/TestYieldToken.sol";
import "alchemix-v3/src/test/mocks/AlchemicTokenV3.sol";
import "alchemix-v3/src/test/mocks/TokenAdapterMock.sol";

// Our contract
import "../src/BasicAlchemistV3Integrator.sol";

/// @dev Simple mock transmuter that returns 0 for queryGraph
/// The original test used address(0x1) which is the ecrecover precompile
contract MockTransmuter {
    function queryGraph(uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract BasicAlchemistV3IntegratorTest is Test {
    // Test contracts
    BasicAlchemistV3Integrator public integrator;

    // Alchemix v3 contracts
    AlchemistV3 public alchemist;
    AlchemistV3Position public positionNFT;
    TransparentUpgradeableProxy public alchemistProxy;

    // Mock tokens
    TestERC20 public underlyingToken;
    TestYieldToken public yieldToken;
    AlchemicTokenV3 public debtToken;
    TokenAdapterMock public tokenAdapter;
    MockTransmuter public mockTransmuter;
    
    // Test addresses
    address public user = address(0xBEEF);
    address public admin = address(0xADDE);
    address public proxyOwner = address(0xDEAD);
    
    // Test constants
    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant DEPOSIT_AMOUNT = 100e18;
    uint256 public constant BORROW_AMOUNT = 50e18;
    
    function setUp() public {
        // Deploy mock tokens
        underlyingToken = new TestERC20(0, 18); // Amount and decimals
        yieldToken = new TestYieldToken(address(underlyingToken)); // Only underlying token address
        debtToken = new AlchemicTokenV3("Test alUSD", "TalUSD", 100); // Name, symbol, flashFee

        // Deploy token adapter
        tokenAdapter = new TokenAdapterMock(address(yieldToken));

        // Deploy mock transmuter (address(0x1) was hitting ecrecover precompile!)
        mockTransmuter = new MockTransmuter();

        // Deploy AlchemistV3 logic contract
        AlchemistV3 alchemistLogic = new AlchemistV3();

        // Setup initialization parameters
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: admin,
            debtToken: address(debtToken),
            underlyingToken: address(underlyingToken),
            yieldToken: address(yieldToken),
            depositCap: type(uint256).max,
            blocksPerYear: 2_600_000,
            minimumCollateralization: 1_111_111_111_111_111_111, // ~111% (90% LTV)
            collateralizationLowerBound: 1_052_631_578_950_000_000, // ~105%
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // ~111%
            tokenAdapter: address(tokenAdapter),
            transmuter: address(mockTransmuter), // Use real mock, not precompile address!
            protocolFee: 100, // 1%
            protocolFeeReceiver: admin,
            liquidatorFee: 300 // 3%
        });
        
        // Deploy AlchemistV3 proxy
        bytes memory alchemistInitData = abi.encodeWithSelector(
            AlchemistV3.initialize.selector,
            params
        );
        
        alchemistProxy = new TransparentUpgradeableProxy(
            address(alchemistLogic),
            proxyOwner,
            alchemistInitData
        );
        
        alchemist = AlchemistV3(address(alchemistProxy));
        
        // Deploy Position NFT
        positionNFT = new AlchemistV3Position(address(alchemist));
        
        // Set position NFT in alchemist
        vm.prank(admin);
        alchemist.setAlchemistPositionNFT(address(positionNFT));
        
        // Setup debt token whitelist and max flash loan
        // Note: test contract has admin role since it deployed the token
        debtToken.setWhitelist(address(alchemist), true);
        debtToken.setMaxFlashLoan(type(uint256).max);
        
        // Deploy our integrator contract
        integrator = new BasicAlchemistV3Integrator(
            address(alchemist),
            address(positionNFT),
            user
        );
        
        // Setup test balances
        underlyingToken.mint(user, INITIAL_BALANCE);
        
        // Convert some underlying tokens to yield tokens for the user
        vm.startPrank(user);
        underlyingToken.approve(address(yieldToken), INITIAL_BALANCE);
        yieldToken.mint(INITIAL_BALANCE, user);
        vm.stopPrank();
        
        // Verify setup
        assertEq(yieldToken.balanceOf(user), INITIAL_BALANCE);
        // Note: underlying tokens are transferred to yield token contract during minting
        // so user's underlying balance will be 0, which is expected
    }
    
    function testCreatePosition() public {
        vm.startPrank(user);
        
        // Approve integrator to spend yield tokens
        yieldToken.approve(address(integrator), DEPOSIT_AMOUNT);
        
        // Create position
        integrator.createPosition(DEPOSIT_AMOUNT);
        
        // Verify position was created
        assertTrue(integrator.positionCreated());
        assertGt(integrator.positionId(), 0);
        
        // Verify position info
        (uint256 collateral, uint256 debt, uint256 earmarked) = integrator.getPositionInfo();
        assertEq(collateral, DEPOSIT_AMOUNT);
        assertEq(debt, 0);
        assertEq(earmarked, 0);
        
        // Verify NFT ownership
        assertEq(positionNFT.ownerOf(integrator.positionId()), address(integrator));
        
        // Verify yield token balance
        assertEq(yieldToken.balanceOf(user), INITIAL_BALANCE - DEPOSIT_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testCreatePositionTwiceShouldRevert() public {
        vm.startPrank(user);
        
        yieldToken.approve(address(integrator), DEPOSIT_AMOUNT * 2);
        
        // First creation should succeed
        integrator.createPosition(DEPOSIT_AMOUNT);
        
        // Second creation should revert
        vm.expectRevert(BasicAlchemistV3Integrator.PositionAlreadyCreated.selector);
        integrator.createPosition(DEPOSIT_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testAddCollateral() public {
        // First create a position
        testCreatePosition();
        
        vm.startPrank(user);
        
        uint256 additionalAmount = 50e18;
        yieldToken.approve(address(integrator), additionalAmount);
        
        // Add more collateral
        integrator.addCollateral(additionalAmount);
        
        // Verify position info
        (uint256 collateral,,) = integrator.getPositionInfo();
        assertEq(collateral, DEPOSIT_AMOUNT + additionalAmount);
        
        vm.stopPrank();
    }
    
    function testBorrowAgainstPosition() public {
        // First create a position
        testCreatePosition();
        
        vm.startPrank(user);
        
        // Check max borrowable amount
        uint256 maxBorrowable = integrator.getMaxBorrowable();
        assertGt(maxBorrowable, 0);
        
        // Borrow against position
        integrator.borrowAgainstPosition(BORROW_AMOUNT);
        
        // Verify position info
        (uint256 collateral, uint256 debt,) = integrator.getPositionInfo();
        assertEq(collateral, DEPOSIT_AMOUNT);
        assertEq(debt, BORROW_AMOUNT);
        
        // Verify user received debt tokens
        assertEq(debtToken.balanceOf(user), BORROW_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testBorrowTooMuchShouldRevert() public {
        // First create a position
        testCreatePosition();
        
        vm.startPrank(user);
        
        uint256 maxBorrowable = integrator.getMaxBorrowable();
        
        // Try to borrow more than max
        vm.expectRevert(AlchemistV3Base.InsufficientCollateral.selector);
        integrator.borrowAgainstPosition(maxBorrowable + 1);
        
        vm.stopPrank();
    }
    
    function testRepayDebt() public {
        // First create position and borrow
        testBorrowAgainstPosition();

        vm.startPrank(user);

        // Move to next block (required for repayment in same block as mint)
        vm.roll(block.number + 1);

        uint256 repayAmount = 25e18;
        yieldToken.approve(address(integrator), repayAmount);

        // Get collateral before repayment
        (uint256 collateralBefore,,) = integrator.getPositionInfo();

        // Repay some debt
        integrator.repayDebt(repayAmount);

        // Verify position info
        (uint256 collateral, uint256 debt,) = integrator.getPositionInfo();

        // Note: Repaying debt via yield tokens incurs a protocol fee (1%)
        // which reduces collateral slightly. Collateral should be less than or equal
        // to the original amount (fee is deducted).
        assertLe(collateral, collateralBefore, "Collateral should not increase");
        assertGt(collateral, collateralBefore * 99 / 100, "Fee should not exceed 1%");

        // Note: actual debt reduction might be slightly different due to conversion rates and fees
        assertLt(debt, BORROW_AMOUNT);

        vm.stopPrank();
    }
    
    function testWithdrawCollateral() public {
        // First create a position
        testCreatePosition();
        
        vm.startPrank(user);
        
        uint256 withdrawAmount = 25e18;
        uint256 initialBalance = yieldToken.balanceOf(user);
        
        // Withdraw some collateral
        integrator.withdrawCollateral(withdrawAmount);
        
        // Verify position info
        (uint256 collateral,,) = integrator.getPositionInfo();
        assertEq(collateral, DEPOSIT_AMOUNT - withdrawAmount);
        
        // Verify user received yield tokens
        assertEq(yieldToken.balanceOf(user), initialBalance + withdrawAmount);
        
        vm.stopPrank();
    }
    
    function testGetPositionHealth() public {
        // First create position and borrow
        testBorrowAgainstPosition();
        
        (
            uint256 currentCollateral,
            uint256 currentDebt,
            uint256 collateralizationRatio,
            bool isHealthy
        ) = integrator.getPositionHealth();
        
        assertEq(currentCollateral, DEPOSIT_AMOUNT);
        assertEq(currentDebt, BORROW_AMOUNT);
        assertGt(collateralizationRatio, 0);
        assertTrue(isHealthy);
    }
    
    function testEmergencyWithdraw() public {
        // First create a position
        testCreatePosition();
        
        vm.startPrank(user);
        
        uint256 initialBalance = yieldToken.balanceOf(user);
        
        // Emergency withdraw (should withdraw all collateral since no debt)
        integrator.emergencyWithdraw();
        
        // Verify position info
        (uint256 collateral,,) = integrator.getPositionInfo();
        assertEq(collateral, 0);
        
        // Verify user received all collateral back
        assertEq(yieldToken.balanceOf(user), initialBalance + DEPOSIT_AMOUNT);
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdrawWithDebt() public {
        // First create position and borrow
        testBorrowAgainstPosition();
        
        vm.startPrank(user);
        
        uint256 initialBalance = yieldToken.balanceOf(user);
        
        // Emergency withdraw (should only withdraw excess collateral)
        integrator.emergencyWithdraw();
        
        // Verify position still has required collateral for debt
        (uint256 collateral, uint256 debt,) = integrator.getPositionInfo();
        assertGt(collateral, 0);
        assertEq(debt, BORROW_AMOUNT);
        
        // Verify some collateral was withdrawn
        assertGt(yieldToken.balanceOf(user), initialBalance);
        
        vm.stopPrank();
    }
    
    function testUnauthorizedAccess() public {
        address unauthorized = address(0xDEAD);
        
        vm.startPrank(unauthorized);
        
        // All functions should revert for unauthorized users
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.createPosition(DEPOSIT_AMOUNT);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.addCollateral(DEPOSIT_AMOUNT);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.borrowAgainstPosition(BORROW_AMOUNT);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.repayDebt(BORROW_AMOUNT);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.withdrawCollateral(DEPOSIT_AMOUNT);
        
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        integrator.emergencyWithdraw();
        
        vm.stopPrank();
    }
    
    function testInvalidAmounts() public {
        vm.startPrank(user);
        
        // Zero amounts should revert
        vm.expectRevert(AlchemistV3Base.InvalidAmount.selector);
        integrator.createPosition(0);
        
        vm.stopPrank();
    }
    
    function testInsufficientBalance() public {
        vm.startPrank(user);
        
        // Try to deposit more than balance
        uint256 excessiveAmount = INITIAL_BALANCE + 1;
        yieldToken.approve(address(integrator), excessiveAmount);
        
        vm.expectRevert(AlchemistV3Base.InsufficientBalance.selector);
        integrator.createPosition(excessiveAmount);
        
        vm.stopPrank();
    }
    
    function testViewFunctionsWithoutPosition() public {
        // All view functions should work even without a position
        (uint256 collateral, uint256 debt, uint256 earmarked) = integrator.getPositionInfo();
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(earmarked, 0);
        
        uint256 maxBorrowable = integrator.getMaxBorrowable();
        assertEq(maxBorrowable, 0);
        
        (
            uint256 currentCollateral,
            uint256 currentDebt,
            uint256 collateralizationRatio,
            bool isHealthy
        ) = integrator.getPositionHealth();
        
        assertEq(currentCollateral, 0);
        assertEq(currentDebt, 0);
        assertEq(collateralizationRatio, type(uint256).max);
        assertTrue(isHealthy);
    }
} 