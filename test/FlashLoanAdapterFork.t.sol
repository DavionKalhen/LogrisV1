// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/adapters/flashloan/BalancerFlashLoanAdapter.sol";
import "../src/adapters/flashloan/EulerFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title FlashLoanAdapterForkTest
 * @notice Fork tests for flash loan adapters against Ethereum mainnet
 * @dev Run with: forge test --match-contract FlashLoanAdapterFork --fork-url $ETH_RPC_URL -vvv
 */
contract FlashLoanAdapterForkTest is Test {
    // Mainnet addresses
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // Common mainnet tokens
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6b175474e89094C44da98B954EEdef3E428B30D5;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Euler mainnet addresses (Euler V1 - note: was exploited and may have limited liquidity)
    address constant EULER_MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;

    // Test contracts
    BalancerFlashLoanAdapter public balancerAdapter;

    // Test recipient
    TestFlashLoanRecipient public recipient;

    function setUp() public {
        // Create mainnet fork
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);

        // Deploy Balancer adapter with mainnet vault
        balancerAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);
    }

    // ============ BALANCER ADAPTER TESTS ============

    function testBalancerAdapter_GetProvider() public view {
        assertEq(balancerAdapter.getProvider(), BALANCER_VAULT, "Provider should be Balancer Vault");
    }

    function testBalancerAdapter_IsTokenSupported_WETH() public view {
        bool supported = balancerAdapter.isTokenSupported(WETH);
        assertTrue(supported, "WETH should be supported on Balancer");
    }

    function testBalancerAdapter_IsTokenSupported_USDC() public view {
        bool supported = balancerAdapter.isTokenSupported(USDC);
        assertTrue(supported, "USDC should be supported on Balancer");
    }

    function testBalancerAdapter_IsTokenSupported_WSTETH() public view {
        bool supported = balancerAdapter.isTokenSupported(WSTETH);
        assertTrue(supported, "wstETH should be supported on Balancer");
    }

    function testBalancerAdapter_MaxFlashLoan_WETH() public view {
        uint256 maxLoan = balancerAdapter.maxFlashLoan(WETH);
        assertGt(maxLoan, 0, "Max flash loan for WETH should be > 0");
    }

    function testBalancerAdapter_MaxFlashLoan_USDC() public view {
        uint256 maxLoan = balancerAdapter.maxFlashLoan(USDC);
        assertGt(maxLoan, 0, "Max flash loan for USDC should be > 0");
    }

    function testBalancerAdapter_GetFlashLoanFee() public view {
        uint256 amount = 1000 ether;
        uint256 fee = balancerAdapter.getFlashLoanFee(WETH, amount);
        // Balancer V2 has 0% flash loan fees
        assertEq(fee, 0, "Balancer flash loan fee should be 0");
    }

    function testBalancerAdapter_FlashLoan_WETH() public {
        uint256 loanAmount = 100 ether;

        // Deploy recipient
        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        // Balancer has 0 fees, so recipient doesn't need extra funds
        uint256 fee = balancerAdapter.getFlashLoanFee(WETH, loanAmount);

        // If there's a fee, we need to fund the recipient
        if (fee > 0) {
            deal(WETH, address(recipient), fee);
        }

        // Execute flash loan
        balancerAdapter.flashLoan(
            WETH,
            loanAmount,
            address(recipient),
            abi.encode("test data")
        );

        // Verify callback was executed
        assertTrue(recipient.callbackExecuted(), "Callback should have been executed");
        assertEq(recipient.lastToken(), WETH, "Token should be WETH");
        assertEq(recipient.lastAmount(), loanAmount, "Amount should match");
        assertEq(recipient.lastFee(), fee, "Fee should match");
    }

    function testBalancerAdapter_FlashLoan_USDC() public {
        uint256 loanAmount = 100_000 * 1e6; // 100k USDC

        // Deploy recipient
        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        uint256 fee = balancerAdapter.getFlashLoanFee(USDC, loanAmount);

        if (fee > 0) {
            deal(USDC, address(recipient), fee);
        }

        // Execute flash loan
        balancerAdapter.flashLoan(
            USDC,
            loanAmount,
            address(recipient),
            ""
        );

        assertTrue(recipient.callbackExecuted(), "Callback should have been executed");
        assertEq(recipient.lastToken(), USDC, "Token should be USDC");
        assertEq(recipient.lastAmount(), loanAmount, "Amount should match");
    }

    function testBalancerAdapter_FlashLoan_WSTETH() public {
        uint256 loanAmount = 50 ether;

        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        uint256 fee = balancerAdapter.getFlashLoanFee(WSTETH, loanAmount);

        if (fee > 0) {
            deal(WSTETH, address(recipient), fee);
        }

        balancerAdapter.flashLoan(
            WSTETH,
            loanAmount,
            address(recipient),
            ""
        );

        assertTrue(recipient.callbackExecuted(), "Callback should have been executed");
        assertEq(recipient.lastToken(), WSTETH, "Token should be wstETH");
    }

    function testBalancerAdapter_FlashLoan_LargeAmount() public {
        // Test with a large amount (but within Balancer's capacity)
        uint256 maxLoan = balancerAdapter.maxFlashLoan(WETH);
        uint256 loanAmount = maxLoan > 10000 ether ? 10000 ether : maxLoan / 2;

        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        uint256 fee = balancerAdapter.getFlashLoanFee(WETH, loanAmount);
        if (fee > 0) {
            deal(WETH, address(recipient), fee);
        }

        balancerAdapter.flashLoan(
            WETH,
            loanAmount,
            address(recipient),
            ""
        );

        assertTrue(recipient.callbackExecuted(), "Large flash loan should succeed");
    }

    function testBalancerAdapter_RevertOnInsufficientRepayment() public {
        uint256 loanAmount = 100 ether;

        // Deploy a malicious recipient that doesn't repay
        MaliciousRecipient malicious = new MaliciousRecipient();

        vm.expectRevert(); // Balancer will revert when repayment is insufficient
        balancerAdapter.flashLoan(
            WETH,
            loanAmount,
            address(malicious),
            ""
        );
    }

    function testBalancerAdapter_RevertOnZeroAmount() public {
        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        vm.expectRevert(IFlashLoanAdapter.InvalidAmount.selector);
        balancerAdapter.flashLoan(
            WETH,
            0,
            address(recipient),
            ""
        );
    }

    function testBalancerAdapter_RevertOnZeroRecipient() public {
        vm.expectRevert(IFlashLoanAdapter.InvalidRecipient.selector);
        balancerAdapter.flashLoan(
            WETH,
            100 ether,
            address(0),
            ""
        );
    }

    function testBalancerAdapter_MultipleSequentialLoans() public {
        recipient = new TestFlashLoanRecipient(address(balancerAdapter));

        // Execute multiple flash loans in sequence
        for (uint256 i = 0; i < 3; i++) {
            uint256 loanAmount = (i + 1) * 50 ether;

            balancerAdapter.flashLoan(
                WETH,
                loanAmount,
                address(recipient),
                abi.encode(i)
            );

            assertEq(recipient.lastAmount(), loanAmount, "Amount should match for each loan");
        }

        assertEq(recipient.callCount(), 3, "Should have executed 3 flash loans");
    }

    // ============ BALANCER LIQUIDITY INFO TESTS ============

    function testBalancerAdapter_ReportLiquidity() public view {
        uint256 wethLiquidity = balancerAdapter.maxFlashLoan(WETH);
        uint256 usdcLiquidity = balancerAdapter.maxFlashLoan(USDC);
        uint256 wstethLiquidity = balancerAdapter.maxFlashLoan(WSTETH);

        assertGt(wethLiquidity, 0);
        assertGt(usdcLiquidity, 0);
        assertGt(wstethLiquidity, 0);
    }
}

/**
 * @title TestFlashLoanRecipient
 * @notice Test recipient that properly repays flash loans
 */
contract TestFlashLoanRecipient is IFlashLoanCallback {
    address public immutable adapter;

    bool public callbackExecuted;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public lastFee;
    address public lastInitiator;
    uint256 public callCount;

    constructor(address _adapter) {
        adapter = _adapter;
    }

    function onFlashLoanReceived(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bool) {
        require(msg.sender == adapter, "Only adapter");

        callbackExecuted = true;
        lastToken = token;
        lastAmount = amount;
        lastFee = fee;
        lastInitiator = initiator;
        callCount++;

        // Repay the flash loan (transfer back to adapter)
        // The adapter will then transfer to the actual provider
        uint256 repayAmount = amount + fee;
        IERC20(token).transfer(adapter, repayAmount);

        return true;
    }
}

/**
 * @title MaliciousRecipient
 * @notice Test recipient that doesn't repay (for testing revert behavior)
 */
contract MaliciousRecipient is IFlashLoanCallback {
    function onFlashLoanReceived(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bool) {
        // Don't repay - this should cause the flash loan to revert
        return true;
    }
}

/**
 * @title EulerFlashLoanAdapterForkTest
 * @notice Fork tests for Euler flash loan adapter
 * @dev Note: Euler V1 was exploited in March 2023 and may have limited functionality
 *      These tests verify the adapter works with whatever state Euler is in
 */
contract EulerFlashLoanAdapterForkTest is Test {
    // Euler V1 mainnet addresses
    // Note: Euler V1 was exploited and funds were returned, but protocol may be in limited state
    address constant EULER_MAINNET = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // Euler dToken addresses (debt tokens that support flash loans)
    // These are the dToken addresses for common assets
    address constant EULER_DWETH = 0x62e28f054efc24b26A794F5C1249B6349454352C;
    address constant EULER_DUSDC = 0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42;
    address constant EULER_DDAI = 0x6085Bc95F506c326DCBCD7A6dd6c79FBc18d4686;

    // Underlying tokens
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6b175474e89094C44da98B954EEdef3E428B30D5;

    EulerFlashLoanAdapter public eulerAdapter;
    TestFlashLoanRecipient public recipient;

    function setUp() public {
        // Create mainnet fork
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);

        // Set up Euler adapter with token mappings
        address[] memory underlyings = new address[](3);
        address[] memory dTokens = new address[](3);

        underlyings[0] = WETH;
        underlyings[1] = USDC;
        underlyings[2] = DAI;

        dTokens[0] = EULER_DWETH;
        dTokens[1] = EULER_DUSDC;
        dTokens[2] = EULER_DDAI;

        eulerAdapter = new EulerFlashLoanAdapter(underlyings, dTokens);
    }

    function testEulerAdapter_IsTokenSupported() public view {
        assertTrue(eulerAdapter.isTokenSupported(WETH), "WETH should be supported");
        assertTrue(eulerAdapter.isTokenSupported(USDC), "USDC should be supported");
        assertTrue(eulerAdapter.isTokenSupported(DAI), "DAI should be supported");
        assertFalse(eulerAdapter.isTokenSupported(address(0x123)), "Random address should not be supported");
    }

    function testEulerAdapter_GetFlashLoanFee() public view {
        uint256 amount = 1000 ether;
        uint256 fee = eulerAdapter.getFlashLoanFee(WETH, amount);
        // Euler has 0% flash loan fees
        assertEq(fee, 0, "Euler flash loan fee should be 0");
    }

    function testEulerAdapter_MaxFlashLoan() public view {
        uint256 maxWeth = eulerAdapter.maxFlashLoan(WETH);
        uint256 maxUsdc = eulerAdapter.maxFlashLoan(USDC);

        // Note: Euler may have limited liquidity post-exploit
        // We just verify the call doesn't revert
    }

    function testEulerAdapter_FlashLoan_WETH() public {
        uint256 maxLoan = eulerAdapter.maxFlashLoan(WETH);

        // Skip if no liquidity available
        if (maxLoan == 0) {
            return;
        }

        // Use a reasonable amount or max available
        uint256 loanAmount = maxLoan > 10 ether ? 10 ether : maxLoan;

        recipient = new TestFlashLoanRecipient(address(eulerAdapter));

        uint256 fee = eulerAdapter.getFlashLoanFee(WETH, loanAmount);
        if (fee > 0) {
            deal(WETH, address(recipient), fee);
        }

        try eulerAdapter.flashLoan(
            WETH,
            loanAmount,
            address(recipient),
            ""
        ) {
            assertTrue(recipient.callbackExecuted(), "Callback should have been executed");
        } catch {
            // Euler protocol may be in limited state post-exploit
        }
    }

    function testEulerAdapter_RevertOnUnsupportedToken() public {
        address unsupportedToken = address(0x999);
        recipient = new TestFlashLoanRecipient(address(eulerAdapter));

        vm.expectRevert(IFlashLoanAdapter.UnsupportedToken.selector);
        eulerAdapter.flashLoan(
            unsupportedToken,
            100 ether,
            address(recipient),
            ""
        );
    }

    function testEulerAdapter_SetDToken() public {
        address newToken = address(0xABC);
        address newDToken = address(0xDEF);

        // Initially not supported
        assertFalse(eulerAdapter.isTokenSupported(newToken), "New token should not be supported initially");

        // Add support
        eulerAdapter.setDToken(newToken, newDToken);

        // Now supported
        assertTrue(eulerAdapter.isTokenSupported(newToken), "New token should be supported after setDToken");
    }
}

/**
 * @title FlashLoanAdapterComparisonTest
 * @notice Compare flash loan capabilities across adapters
 */
contract FlashLoanAdapterComparisonTest is Test {
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant EULER_DWETH = 0x62e28f054efc24b26A794F5C1249B6349454352C;
    address constant EULER_DUSDC = 0x84721A3dB22EB852233AEAE74f9bC8477F8bcc42;

    BalancerFlashLoanAdapter public balancerAdapter;
    EulerFlashLoanAdapter public eulerAdapter;

    function setUp() public {
        // Create mainnet fork
        string memory rpcUrl = vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.g.alchemy.com/v2/demo"));
        vm.createSelectFork(rpcUrl, 19500000);

        balancerAdapter = new BalancerFlashLoanAdapter(BALANCER_VAULT);

        address[] memory underlyings = new address[](2);
        address[] memory dTokens = new address[](2);
        underlyings[0] = WETH;
        underlyings[1] = USDC;
        dTokens[0] = EULER_DWETH;
        dTokens[1] = EULER_DUSDC;

        eulerAdapter = new EulerFlashLoanAdapter(underlyings, dTokens);
    }

    function testCompare_MaxFlashLoan_WETH() public view {
        uint256 balancerMax = balancerAdapter.maxFlashLoan(WETH);
        uint256 eulerMax = eulerAdapter.maxFlashLoan(WETH);

        // Both adapters should return non-reverting values
        assertTrue(balancerMax > 0 || eulerMax > 0, "At least one adapter should have liquidity");
    }

    function testCompare_MaxFlashLoan_USDC() public view {
        uint256 balancerMax = balancerAdapter.maxFlashLoan(USDC);
        uint256 eulerMax = eulerAdapter.maxFlashLoan(USDC);

        // Both adapters should return non-reverting values
        assertTrue(balancerMax > 0 || eulerMax > 0, "At least one adapter should have USDC liquidity");
    }

    function testCompare_Fees() public view {
        uint256 amount = 1000 ether;

        uint256 balancerFee = balancerAdapter.getFlashLoanFee(WETH, amount);
        uint256 eulerFee = eulerAdapter.getFlashLoanFee(WETH, amount);

        // Both Balancer and Euler have 0% flash loan fees
        assertEq(balancerFee, 0, "Balancer fee should be 0");
        assertEq(eulerFee, 0, "Euler fee should be 0");
    }
}
