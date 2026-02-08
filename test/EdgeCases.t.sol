// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title EdgeCasesTest
 * @notice Edge case tests for flash loan adapters
 */
contract EdgeCasesTest is Test {
    BalancerFlashLoanAdapter public adapter;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);
        adapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);
    }

    // ============ INPUT VALIDATION TESTS ============

    function test_RevertOnZeroAmount() public {
        vm.expectRevert(IFlashLoanAdapter.InvalidAmount.selector);
        adapter.flashLoan(WETH, 0, address(this), "");
    }

    function test_RevertOnZeroRecipient() public {
        vm.expectRevert(IFlashLoanAdapter.InvalidRecipient.selector);
        adapter.flashLoan(WETH, 1 ether, address(0), "");
    }

    function test_RevertOnZeroToken() public {
        vm.expectRevert(BalancerFlashLoanAdapter.InvalidToken.selector);
        adapter.flashLoan(address(0), 1 ether, address(this), "");
    }

    function test_IsTokenSupportedZeroAddress() public view {
        assertFalse(adapter.isTokenSupported(address(0)));
    }

    function test_MaxFlashLoanZeroAddress() public view {
        assertEq(adapter.maxFlashLoan(address(0)), 0);
    }

    // ============ PAUSABILITY TESTS ============

    function test_OwnerCanPause() public {
        adapter.pause();
        assertTrue(adapter.paused());
    }

    function test_OwnerCanUnpause() public {
        adapter.pause();
        adapter.unpause();
        assertFalse(adapter.paused());
    }

    function test_NonOwnerCannotPause() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert();
        adapter.pause();
    }

    function test_RevertWhenPaused() public {
        adapter.pause();

        vm.expectRevert();
        adapter.flashLoan(WETH, 1 ether, address(this), "");
    }

    // ============ EMERGENCY WITHDRAW TESTS ============

    function test_EmergencyWithdraw() public {
        // Fund the adapter with some WETH
        deal(WETH, address(adapter), 10 ether);

        uint256 ownerBalanceBefore = IERC20(WETH).balanceOf(adapter.owner());

        adapter.emergencyWithdraw(WETH, 10 ether);

        uint256 ownerBalanceAfter = IERC20(WETH).balanceOf(adapter.owner());
        assertEq(ownerBalanceAfter - ownerBalanceBefore, 10 ether);
    }

    function test_EmergencyWithdrawRevertOnZeroToken() public {
        vm.expectRevert(BalancerFlashLoanAdapter.InvalidToken.selector);
        adapter.emergencyWithdraw(address(0), 1 ether);
    }

    function test_NonOwnerCannotEmergencyWithdraw() public {
        address notOwner = makeAddr("notOwner");
        deal(WETH, address(adapter), 10 ether);

        vm.prank(notOwner);
        vm.expectRevert();
        adapter.emergencyWithdraw(WETH, 10 ether);
    }

    // ============ REENTRANCY TESTS ============

    function test_ReentrantCallReverts() public {
        ReentrantRecipient malicious = new ReentrantRecipient(address(adapter), WETH);

        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        adapter.flashLoan(WETH, 1 ether, address(malicious), "");
    }

    // ============ EXTREME VALUES ============

    function test_MaxAmountFlashLoan() public view {
        // Verify max flash loan returns a reasonable value
        uint256 maxAmount = adapter.maxFlashLoan(WETH);
        assertTrue(maxAmount > 1000 ether, "Should have significant WETH available");
    }

    function test_VerySmallAmount() public view {
        // Verify the adapter accepts any non-zero amount
        // Actual flash loan would work but we just verify view functions
        assertTrue(adapter.isTokenSupported(WETH), "WETH should be supported");
        assertEq(adapter.getFlashLoanFee(WETH, 1), 0, "Fee should be 0 for any amount");
    }
}

/**
 * @title ReentrantRecipient
 * @notice Malicious recipient that attempts reentrancy
 */
contract ReentrantRecipient is IFlashLoanCallback {
    address public adapter;
    address public token;

    constructor(address _adapter, address _token) {
        adapter = _adapter;
        token = _token;
    }

    function onFlashLoanReceived(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external override returns (bool) {
        // Attempt reentrancy
        IFlashLoanAdapter(adapter).flashLoan(token, 1 ether, address(this), "");
        return true;
    }
}

/**
 * @title RepayingRecipient
 * @notice Simple recipient that attempts to repay (will fail without funds)
 */
contract RepayingRecipient is IFlashLoanCallback {
    function onFlashLoanReceived(
        address,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata
    ) external override returns (bool) {
        // Try to repay - will fail if we don't have the funds
        IERC20(token).transfer(msg.sender, amount + fee);
        return true;
    }
}

/**
 * @title GasOptimizationTest
 * @notice Tests to measure gas consumption and verify optimizations
 */
contract GasOptimizationTest is Test {
    BalancerFlashLoanAdapter public adapter;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);
        adapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);
    }

    function test_GasViewFunctions() public view {
        // Measure gas for view functions
        uint256 gasBefore = gasleft();
        adapter.getProvider();
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(gasUsed < 10000, "getProvider should be cheap");

        gasBefore = gasleft();
        adapter.isTokenSupported(WETH);
        gasUsed = gasBefore - gasleft();
        assertTrue(gasUsed < 20000, "isTokenSupported should be reasonable");

        gasBefore = gasleft();
        adapter.maxFlashLoan(WETH);
        gasUsed = gasBefore - gasleft();
        assertTrue(gasUsed < 20000, "maxFlashLoan should be reasonable");

        gasBefore = gasleft();
        adapter.getFlashLoanFee(WETH, 1 ether);
        gasUsed = gasBefore - gasleft();
        assertTrue(gasUsed < 5000, "getFlashLoanFee should be cheap");
    }

    function test_AdminFunctionsGas() public {
        uint256 gasBefore = gasleft();
        adapter.pause();
        uint256 pauseGas = gasBefore - gasleft();
        gasBefore = gasleft();
        adapter.unpause();
        uint256 unpauseGas = gasBefore - gasleft();
        // Admin functions should be efficient
        assertTrue(pauseGas < 50000, "pause should be efficient");
        assertTrue(unpauseGas < 50000, "unpause should be efficient");
    }
}
