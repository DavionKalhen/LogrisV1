// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/adapters/flashloan/AaveV3FlashLoanAdapter.sol";
import "../src/adapters/WstETHAdapter.sol";
import "../src/converters/WETHToWstETHConverter.sol";
import "../src/interfaces/ISwapper.sol";

// ============================================================================
// Mocks
// ============================================================================

/// @dev Minimal ERC20 mock with mint capability
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Mock Aave V3 Pool for flash loan tests
contract MockAaveV3Pool {
    uint128 public premiumTotal;

    constructor(uint128 _premium) {
        premiumTotal = _premium;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return premiumTotal;
    }

    /// @dev Simplified flashLoanSimple: calls executeOperation on the receiver
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 /* referralCode */
    ) external {
        // Transfer tokens to the receiver (simulating the pool lending)
        MockERC20(asset).transfer(receiverAddress, amount);

        // Calculate premium
        uint256 premium = (amount * premiumTotal) / 10_000;

        // Call executeOperation on the receiver
        IFlashLoanSimpleReceiver(receiverAddress).executeOperation(
            asset,
            amount,
            premium,
            receiverAddress, // initiator = receiver for our adapter
            params
        );

        // Pull back repayment (amount + premium)
        MockERC20(asset).transferFrom(receiverAddress, address(this), amount + premium);
    }
}

/// @dev Mock ISwapper that supports a configurable pair
contract MockSwapper is ISwapper {
    address public pairA;
    address public pairB;

    constructor(address _pairA, address _pairB) {
        pairA = _pairA;
        pairB = _pairB;
    }

    function isSupportedPair(address tokenA, address tokenB) external view override returns (bool) {
        return (tokenA == pairA && tokenB == pairB) || (tokenA == pairB && tokenB == pairA);
    }

    function swapDebtToUnderlying(uint256, uint256, address, bytes calldata)
        external pure override returns (uint256)
    {
        return 0;
    }

    function swapUnderlyingToDebt(uint256, uint256, address, bytes calldata)
        external pure override returns (uint256)
    {
        return 0;
    }

    function previewSwapDebtToUnderlying(uint256 debtAmount)
        external pure override returns (uint256, uint256)
    {
        return (debtAmount, debtAmount);
    }

    function previewSwapUnderlyingToDebt(uint256 underlyingAmount)
        external pure override returns (uint256, uint256)
    {
        return (underlyingAmount, underlyingAmount);
    }

    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 1e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 1e18; }
    function getSwapFee() external pure override returns (uint256) { return 0; }
    function getSlippageTolerance() external pure override returns (uint256) { return 100; }
}

/// @dev Mock ISwapper that returns false for all pairs
contract MockSwapperUnsupported is ISwapper {
    function isSupportedPair(address, address) external pure override returns (bool) {
        return false;
    }

    function swapDebtToUnderlying(uint256, uint256, address, bytes calldata)
        external pure override returns (uint256) { return 0; }
    function swapUnderlyingToDebt(uint256, uint256, address, bytes calldata)
        external pure override returns (uint256) { return 0; }
    function previewSwapDebtToUnderlying(uint256)
        external pure override returns (uint256, uint256) { return (0, 0); }
    function previewSwapUnderlyingToDebt(uint256)
        external pure override returns (uint256, uint256) { return (0, 0); }
    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 1e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 1e18; }
    function getSwapFee() external pure override returns (uint256) { return 0; }
    function getSlippageTolerance() external pure override returns (uint256) { return 0; }
}

/// @dev Mock wstETH that provides stEthPerToken
contract MockWstETH {
    uint256 private _stEthPerToken;

    constructor(uint256 rate) {
        _stEthPerToken = rate;
    }

    function stEthPerToken() external view returns (uint256) {
        return _stEthPerToken;
    }

    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256) {
        return (_stETHAmount * 1e18) / _stEthPerToken;
    }

    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256) {
        return (_wstETHAmount * _stEthPerToken) / 1e18;
    }
}

/// @dev Helper that rejects ETH transfers (for testing ETHTransferFailed)
contract ETHRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

// ============================================================================
// AaveV3FlashLoanAdapter Unit Tests
// ============================================================================

contract AaveV3FlashLoanAdapterUnitTest is Test {
    AaveV3FlashLoanAdapter private adapter;
    MockAaveV3Pool private mockPool;
    MockERC20 private token;
    address private owner;
    address private nonOwner = address(0xBEEF);

    function setUp() public {
        owner = address(this);
        mockPool = new MockAaveV3Pool(5); // 5 bps = 0.05%
        adapter = new AaveV3FlashLoanAdapter(address(mockPool));
        token = new MockERC20("Test Token", "TKN");
    }

    // --- Constructor ---

    function testConstructorWithCustomPool() public view {
        assertEq(address(adapter.AAVE_POOL()), address(mockPool));
        assertEq(adapter.getProvider(), address(mockPool));
    }

    function testConstructorWithZeroAddressUsesDefault() public {
        AaveV3FlashLoanAdapter defaultAdapter = new AaveV3FlashLoanAdapter(address(0));
        assertEq(address(defaultAdapter.AAVE_POOL()), defaultAdapter.AAVE_V3_POOL());
    }

    // --- flashLoan input validation ---

    function testFlashLoanRevertsOnZeroAmount() public {
        vm.expectRevert(IFlashLoanAdapter.InvalidAmount.selector);
        adapter.flashLoan(address(token), 0, address(0x1234), "");
    }

    function testFlashLoanRevertsOnZeroRecipient() public {
        vm.expectRevert(IFlashLoanAdapter.InvalidRecipient.selector);
        adapter.flashLoan(address(token), 1 ether, address(0), "");
    }

    function testFlashLoanRevertsOnZeroToken() public {
        vm.expectRevert(AaveV3FlashLoanAdapter.InvalidToken.selector);
        adapter.flashLoan(address(0), 1 ether, address(0x1234), "");
    }

    // --- flashLoan paused ---

    function testFlashLoanRevertsWhenPaused() public {
        adapter.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        adapter.flashLoan(address(token), 1 ether, address(0x1234), "");
    }

    // --- getFlashLoanFee ---

    function testGetFlashLoanFeeCalculation() public view {
        // Pool premium is 5 bps. Fee = amount * 5 / 10000
        uint256 fee = adapter.getFlashLoanFee(address(token), 10_000 ether);
        assertEq(fee, 5 ether); // 10_000 * 5 / 10_000 = 5
    }

    function testGetFlashLoanFeeZeroAmount() public view {
        uint256 fee = adapter.getFlashLoanFee(address(token), 0);
        assertEq(fee, 0);
    }

    function testGetFlashLoanFeeWithDifferentPremium() public {
        MockAaveV3Pool highFeePool = new MockAaveV3Pool(50); // 50 bps = 0.5%
        AaveV3FlashLoanAdapter highFeeAdapter = new AaveV3FlashLoanAdapter(address(highFeePool));
        uint256 fee = highFeeAdapter.getFlashLoanFee(address(token), 1000 ether);
        assertEq(fee, 5 ether); // 1000 * 50 / 10_000 = 5
    }

    // --- isTokenSupported ---

    function testIsTokenSupportedReturnsTrueWhenPoolHasBalance() public {
        // Mint tokens to the mock pool so balanceOf(pool) > 0
        token.mint(address(mockPool), 100 ether);
        assertTrue(adapter.isTokenSupported(address(token)));
    }

    function testIsTokenSupportedReturnsFalseWhenPoolHasNoBalance() public view {
        assertFalse(adapter.isTokenSupported(address(token)));
    }

    function testIsTokenSupportedReturnsFalseForZeroAddress() public view {
        assertFalse(adapter.isTokenSupported(address(0)));
    }

    // --- maxFlashLoan ---

    function testMaxFlashLoanReturnsPoolBalance() public {
        token.mint(address(mockPool), 500 ether);
        assertEq(adapter.maxFlashLoan(address(token)), 500 ether);
    }

    function testMaxFlashLoanReturnsZeroForZeroAddress() public view {
        assertEq(adapter.maxFlashLoan(address(0)), 0);
    }

    function testMaxFlashLoanReturnsZeroWhenPoolEmpty() public view {
        assertEq(adapter.maxFlashLoan(address(token)), 0);
    }

    // --- getProvider ---

    function testGetProviderReturnsPoolAddress() public view {
        assertEq(adapter.getProvider(), address(mockPool));
    }

    // --- pause / unpause ---

    function testOwnerCanPause() public {
        adapter.pause();
        assertTrue(adapter.paused());
    }

    function testOwnerCanUnpause() public {
        adapter.pause();
        adapter.unpause();
        assertFalse(adapter.paused());
    }

    function testNonOwnerCannotPause() public {
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner)
        );
        adapter.pause();
    }

    function testNonOwnerCannotUnpause() public {
        adapter.pause();
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner)
        );
        adapter.unpause();
    }

    // --- emergencyWithdraw ---

    function testEmergencyWithdrawByOwner() public {
        token.mint(address(adapter), 10 ether);
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        adapter.emergencyWithdraw(address(token), 10 ether);

        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(owner), ownerBalanceBefore + 10 ether);
    }

    function testEmergencyWithdrawEmitsEvent() public {
        token.mint(address(adapter), 5 ether);

        vm.expectEmit(true, true, false, true);
        emit AaveV3FlashLoanAdapter.EmergencyWithdrawal(address(token), 5 ether, owner);
        adapter.emergencyWithdraw(address(token), 5 ether);
    }

    function testEmergencyWithdrawRevertsForNonOwner() public {
        token.mint(address(adapter), 10 ether);
        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner)
        );
        adapter.emergencyWithdraw(address(token), 10 ether);
    }

    function testEmergencyWithdrawRevertsOnZeroToken() public {
        vm.expectRevert(AaveV3FlashLoanAdapter.InvalidToken.selector);
        adapter.emergencyWithdraw(address(0), 1 ether);
    }

    function testEmergencyWithdrawPartialAmount() public {
        token.mint(address(adapter), 10 ether);
        adapter.emergencyWithdraw(address(token), 3 ether);
        assertEq(token.balanceOf(address(adapter)), 7 ether);
        assertEq(token.balanceOf(owner), 3 ether);
    }

    // --- Owner ---

    function testOwnerIsDeployer() public view {
        assertEq(adapter.owner(), owner);
    }
}

// ============================================================================
// WstETHAdapter Unit Tests
// ============================================================================

contract WstETHAdapterUnitTest is Test {
    address private owner;
    address private nonOwner = address(0xBEEF);

    // Mainnet constant addresses used by WstETHAdapter
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        owner = address(this);
    }

    // --- Helper: deploy adapter with mock swapper supporting stETH/WETH ---

    function _deployAdapter(uint256 minOutBps) internal returns (WstETHAdapter) {
        MockSwapper swapper = new MockSwapper(STETH, WETH);
        return new WstETHAdapter(address(swapper), minOutBps, owner);
    }

    // --- Constructor: reverts on zero swapper ---

    function testConstructorRevertsOnZeroSwapper() public {
        vm.expectRevert(WstETHAdapter.ZeroAddress.selector);
        new WstETHAdapter(address(0), 9950, owner);
    }

    // --- Constructor: reverts on invalid minOutBps ---

    function testConstructorRevertsOnZeroMinOutBps() public {
        MockSwapper swapper = new MockSwapper(STETH, WETH);
        vm.expectRevert(WstETHAdapter.InvalidMinOutBps.selector);
        new WstETHAdapter(address(swapper), 0, owner);
    }

    function testConstructorRevertsOnMinOutBpsAbove10000() public {
        MockSwapper swapper = new MockSwapper(STETH, WETH);
        vm.expectRevert(WstETHAdapter.InvalidMinOutBps.selector);
        new WstETHAdapter(address(swapper), 10_001, owner);
    }

    // --- Constructor: reverts on unsupported pair ---

    function testConstructorRevertsOnUnsupportedPair() public {
        MockSwapperUnsupported unsupported = new MockSwapperUnsupported();
        vm.expectRevert(WstETHAdapter.UnsupportedPair.selector);
        new WstETHAdapter(address(unsupported), 9950, owner);
    }

    // --- Constructor: valid construction stores immutables ---

    function testConstructorStoresImmutables() public {
        MockSwapper swapper = new MockSwapper(STETH, WETH);
        WstETHAdapter adapter = new WstETHAdapter(address(swapper), 9950, owner);
        assertEq(address(adapter.SWAPPER()), address(swapper));
        assertEq(adapter.MIN_OUT_BPS(), 9950);
        assertEq(adapter.owner(), owner);
    }

    function testConstructorAcceptsBoundaryMinOutBps() public {
        // minOutBps = 1 (minimum valid)
        MockSwapper swapper1 = new MockSwapper(STETH, WETH);
        WstETHAdapter adapter1 = new WstETHAdapter(address(swapper1), 1, owner);
        assertEq(adapter1.MIN_OUT_BPS(), 1);

        // minOutBps = 10000 (maximum valid, no slippage tolerance)
        MockSwapper swapper2 = new MockSwapper(STETH, WETH);
        WstETHAdapter adapter2 = new WstETHAdapter(address(swapper2), 10_000, owner);
        assertEq(adapter2.MIN_OUT_BPS(), 10_000);
    }

    // --- token() ---

    function testTokenReturnsWstETH() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        assertEq(adapter.token(), WSTETH);
    }

    // --- underlyingToken() ---

    function testUnderlyingTokenReturnsWETH() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        assertEq(adapter.underlyingToken(), WETH);
    }

    // --- version() ---

    function testVersionReturnsExpected() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        assertEq(adapter.version(), "1.0.0");
    }

    // --- price() ---
    // price() calls IWstETH(WSTETH).stEthPerToken() on a hardcoded mainnet address.
    // We use vm.etch to place a mock at the WSTETH address so the call succeeds.

    function testPriceCallsStEthPerToken() public {
        WstETHAdapter adapter = _deployAdapter(9950);

        // Deploy mock wstETH with a known exchange rate
        MockWstETH mockWst = new MockWstETH(1.15e18);

        // Etch the mock bytecode at the hardcoded WSTETH address
        vm.etch(WSTETH, address(mockWst).code);

        // Store the rate in the etched contract's storage
        // MockWstETH stores _stEthPerToken at slot 0
        vm.store(WSTETH, bytes32(uint256(0)), bytes32(uint256(1.15e18)));

        uint256 p = adapter.price();
        assertEq(p, 1.15e18);
    }

    // --- rescueETH ---

    function testRescueETHByOwner() public {
        WstETHAdapter adapter = _deployAdapter(9950);

        // Send ETH to the adapter
        vm.deal(address(adapter), 2 ether);

        address payable recipient = payable(address(0xCAFE));
        adapter.rescueETH(recipient);
        assertEq(recipient.balance, 2 ether);
        assertEq(address(adapter).balance, 0);
    }

    function testRescueETHEmitsEvent() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        vm.deal(address(adapter), 1 ether);

        address payable recipient = payable(address(0xCAFE));
        vm.expectEmit(true, true, false, true);
        emit WstETHAdapter.ETHRescued(1 ether, recipient);
        adapter.rescueETH(recipient);
    }

    function testRescueETHRevertsOnZeroRecipient() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        vm.deal(address(adapter), 1 ether);

        vm.expectRevert(WstETHAdapter.ZeroAddress.selector);
        adapter.rescueETH(payable(address(0)));
    }

    function testRescueETHRevertsWhenNoETH() public {
        WstETHAdapter adapter = _deployAdapter(9950);

        vm.expectRevert(WstETHAdapter.NoETHToRescue.selector);
        adapter.rescueETH(payable(address(0xCAFE)));
    }

    function testRescueETHRevertsForNonOwner() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        vm.deal(address(adapter), 1 ether);

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner)
        );
        adapter.rescueETH(payable(address(0xCAFE)));
    }

    function testRescueETHRevertsWhenTransferFails() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        vm.deal(address(adapter), 1 ether);

        ETHRejecter rejecter = new ETHRejecter();

        vm.expectRevert(WstETHAdapter.ETHTransferFailed.selector);
        adapter.rescueETH(payable(address(rejecter)));
    }

    // --- receive() ---

    function testAdapterCanReceiveETH() public {
        WstETHAdapter adapter = _deployAdapter(9950);
        vm.deal(address(this), 1 ether);
        (bool success,) = address(adapter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(adapter).balance, 1 ether);
    }
}

// ============================================================================
// WETHToWstETHConverter Unit Tests
// ============================================================================

contract WETHToWstETHConverterUnitTest is Test {
    address private owner;
    address private nonOwner = address(0xBEEF);

    // Populated in setUp via makeAddr
    address private weth;
    address private steth;
    address private wsteth;
    address private curvePool;

    function setUp() public {
        owner = address(this);
        // Use deterministic addresses for the tokens
        weth = makeAddr("weth");
        steth = makeAddr("steth");
        wsteth = makeAddr("wsteth");
        curvePool = makeAddr("curvePool");
    }

    // --- Helper: deploy converter with valid params ---

    function _deployConverter() internal returns (WETHToWstETHConverter) {
        return new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool,
            0, // ethIndex
            1, // stethIndex
            9950, // minOutBps
            owner
        );
    }

    // --- Constructor: reverts on zero addresses ---

    function testConstructorRevertsOnZeroWETH() public {
        vm.expectRevert(WETHToWstETHConverter.ZeroAddress.selector);
        new WETHToWstETHConverter(
            address(0), steth, wsteth, curvePool, 0, 1, 9950, owner
        );
    }

    function testConstructorRevertsOnZeroSTETH() public {
        vm.expectRevert(WETHToWstETHConverter.ZeroAddress.selector);
        new WETHToWstETHConverter(
            weth, address(0), wsteth, curvePool, 0, 1, 9950, owner
        );
    }

    function testConstructorRevertsOnZeroWSTETH() public {
        vm.expectRevert(WETHToWstETHConverter.ZeroAddress.selector);
        new WETHToWstETHConverter(
            weth, steth, address(0), curvePool, 0, 1, 9950, owner
        );
    }

    function testConstructorRevertsOnZeroCurvePool() public {
        vm.expectRevert(WETHToWstETHConverter.ZeroAddress.selector);
        new WETHToWstETHConverter(
            weth, steth, wsteth, address(0), 0, 1, 9950, owner
        );
    }

    // --- Constructor: reverts on invalid minOutBps ---

    function testConstructorRevertsOnZeroMinOutBps() public {
        vm.expectRevert(WETHToWstETHConverter.InvalidMinOutBps.selector);
        new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool, 0, 1, 0, owner
        );
    }

    function testConstructorRevertsOnMinOutBpsAbove10000() public {
        vm.expectRevert(WETHToWstETHConverter.InvalidMinOutBps.selector);
        new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool, 0, 1, 10_001, owner
        );
    }

    // --- Constructor: valid construction stores immutables ---

    function testConstructorStoresImmutables() public {
        WETHToWstETHConverter converter = _deployConverter();
        assertEq(converter.WETH(), weth);
        assertEq(converter.STETH(), steth);
        assertEq(converter.WSTETH(), wsteth);
        assertEq(converter.CURVE_STETH_POOL(), curvePool);
        assertEq(converter.CURVE_ETH_INDEX(), 0);
        assertEq(converter.CURVE_STETH_INDEX(), 1);
        assertEq(converter.MIN_OUT_BPS(), 9950);
        assertEq(converter.owner(), owner);
    }

    function testConstructorAcceptsBoundaryMinOutBps() public {
        // minOutBps = 1 (minimum valid)
        WETHToWstETHConverter c1 = new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool, 0, 1, 1, owner
        );
        assertEq(c1.MIN_OUT_BPS(), 1);

        // minOutBps = 10000 (maximum valid)
        WETHToWstETHConverter c2 = new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool, 0, 1, 10_000, owner
        );
        assertEq(c2.MIN_OUT_BPS(), 10_000);
    }

    // --- yieldToken() ---

    function testYieldTokenReturnsWSTETH() public {
        WETHToWstETHConverter converter = _deployConverter();
        assertEq(converter.yieldToken(), wsteth);
    }

    // --- underlyingToken() ---

    function testUnderlyingTokenReturnsWETH() public {
        WETHToWstETHConverter converter = _deployConverter();
        assertEq(converter.underlyingToken(), weth);
    }

    // --- rescueETH ---

    function testRescueETHByOwner() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(converter), 3 ether);

        address payable recipient = payable(address(0xCAFE));
        converter.rescueETH(recipient);
        assertEq(recipient.balance, 3 ether);
        assertEq(address(converter).balance, 0);
    }

    function testRescueETHEmitsEvent() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(converter), 2 ether);

        address payable recipient = payable(address(0xCAFE));
        vm.expectEmit(true, true, false, true);
        emit WETHToWstETHConverter.ETHRescued(2 ether, recipient);
        converter.rescueETH(recipient);
    }

    function testRescueETHRevertsOnZeroRecipient() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(converter), 1 ether);

        vm.expectRevert(WETHToWstETHConverter.ZeroAddress.selector);
        converter.rescueETH(payable(address(0)));
    }

    function testRescueETHRevertsWhenNoETH() public {
        WETHToWstETHConverter converter = _deployConverter();

        vm.expectRevert(WETHToWstETHConverter.NoETHToRescue.selector);
        converter.rescueETH(payable(address(0xCAFE)));
    }

    function testRescueETHRevertsForNonOwner() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(converter), 1 ether);

        vm.prank(nonOwner);
        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner)
        );
        converter.rescueETH(payable(address(0xCAFE)));
    }

    function testRescueETHRevertsWhenTransferFails() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(converter), 1 ether);

        ETHRejecter rejecter = new ETHRejecter();

        vm.expectRevert(WETHToWstETHConverter.ETHTransferFailed.selector);
        converter.rescueETH(payable(address(rejecter)));
    }

    // --- receive() ---

    function testConverterCanReceiveETH() public {
        WETHToWstETHConverter converter = _deployConverter();
        vm.deal(address(this), 1 ether);
        (bool success,) = address(converter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(converter).balance, 1 ether);
    }

    // --- Owner ---

    function testOwnerIsSetCorrectly() public {
        WETHToWstETHConverter converter = _deployConverter();
        assertEq(converter.owner(), owner);
    }

    function testOwnerCanBeNonDeployer() public {
        address customOwner = address(0xDEAD);
        WETHToWstETHConverter converter = new WETHToWstETHConverter(
            weth, steth, wsteth, curvePool, 0, 1, 9950, customOwner
        );
        assertEq(converter.owner(), customOwner);
    }
}
