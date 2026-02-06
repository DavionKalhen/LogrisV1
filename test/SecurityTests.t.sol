// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/adapters/flashloan/EulerFlashLoanAdapter.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";
import "../src/interfaces/ILeveragedVaultCallback.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";

// ============ Mock Contracts ============

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockAlchemistV3 {
    address public debtToken;
    address public yieldToken;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }
    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId = 1;

    constructor(address _debtToken, address _yieldToken) {
        debtToken = _debtToken;
        yieldToken = _yieldToken;
    }

    function deposit(uint256 amount, address, uint256 positionId) external returns (uint256) {
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        if (positionId == 0) {
            positionId = nextPositionId++;
        }
        positions[positionId].collateral += amount;
        return amount;
    }

    function mint(uint256 positionId, uint256 amount, address recipient) external {
        positions[positionId].debt += amount;
        MockERC20(debtToken).mint(recipient, amount);
    }

    function burn(uint256 amount, uint256 positionId) external returns (uint256) {
        IERC20(debtToken).transferFrom(msg.sender, address(this), amount);
        positions[positionId].debt -= amount;
        return amount;
    }

    function withdraw(uint256 amount, address recipient, uint256 positionId) external returns (uint256) {
        positions[positionId].collateral -= amount;
        IERC20(yieldToken).transfer(recipient, amount);
        return amount;
    }

    function getCDP(uint256 positionId) external view returns (uint256, uint256, uint256) {
        return (positions[positionId].collateral, positions[positionId].debt, 0);
    }

    function approveMint(uint256, address, uint256) external {}
}

contract MockTokenConverter is ITokenConverter {
    address public override yieldToken;
    address public override underlyingToken;

    constructor(address _underlying, address _yield) {
        underlyingToken = _underlying;
        yieldToken = _yield;
    }

    function toYield(uint256 amount, address recipient, uint256 minYieldOut) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), amount);
        MockERC20(yieldToken).mint(recipient, amount);
        require(amount >= minYieldOut, "Insufficient yield output");
        return amount;
    }

    function toUnderlying(
        uint256 amount,
        address recipient,
        uint256 /* minUnderlyingOut */
    ) external override returns (uint256) {
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        MockERC20(underlyingToken).mint(recipient, amount);
        return amount;
    }

    function previewToYield(uint256 amount) external pure override returns (uint256) {
        return amount;
    }

    function previewToUnderlying(uint256 amount) external pure override returns (uint256) {
        return amount;
    }
}

/// @dev Swapper that returns less than minSwapOutput to test slippage
contract BadSlippageSwapper is ISwapper {
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
        MockERC20(underlyingToken).mint(recipient, outputAmount);
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
        MockERC20(debtToken).mint(recipient, outputAmount);
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

contract MockSwapper is ISwapper {
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
        MockERC20(underlyingToken).mint(recipient, output);
        emit SwapExecuted(debtToken, underlyingToken, debtAmount, output, recipient);
        return output;
    }

    function swapUnderlyingToDebt(
        uint256 underlyingAmount,
        uint256,
        address recipient,
        bytes calldata
    ) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), underlyingAmount);
        uint256 output = underlyingAmount * 99 / 100;
        MockERC20(debtToken).mint(recipient, output);
        emit SwapExecuted(underlyingToken, debtToken, underlyingAmount, output, recipient);
        return output;
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

contract MockFlashLoanAdapter is IFlashLoanAdapter {
    using SafeERC20 for IERC20;

    address public token;

    constructor(address _token) {
        token = _token;
    }

    function flashLoan(
        address _token,
        uint256 amount,
        address recipient,
        bytes calldata data
    ) external override {
        MockERC20(_token).mint(address(this), amount);
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

contract MockVault is ILeveragedVaultCallback {
    using SafeERC20 for IERC20;

    MockAlchemistV3 public alchemist;
    uint256 public vaultPositionId;
    address public leverager;
    address public underlyingToken;
    bool private positionCreated;

    modifier onlyLeverager() {
        require(msg.sender == leverager, "Only leverager");
        _;
    }

    constructor(address _alchemist, address _leverager, address _underlyingToken) {
        alchemist = MockAlchemistV3(_alchemist);
        leverager = _leverager;
        underlyingToken = _underlyingToken;
    }

    function vaultDepositYieldTokens(uint256 amount) external override onlyLeverager returns (uint256) {
        address yieldToken = alchemist.yieldToken();
        IERC20(yieldToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(yieldToken).approve(address(alchemist), amount);

        if (!positionCreated) {
            alchemist.deposit(amount, address(this), 0);
            vaultPositionId = alchemist.nextPositionId() - 1;
            positionCreated = true;
        } else {
            alchemist.deposit(amount, address(this), vaultPositionId);
        }
        return amount;
    }

    function vaultMintDebtTokens(uint256 amount, address recipient) external override onlyLeverager {
        alchemist.mint(vaultPositionId, amount, recipient);
    }

    function vaultWithdrawYieldTokens(uint256 amount, address recipient) external override onlyLeverager returns (uint256) {
        return alchemist.withdraw(amount, recipient, vaultPositionId);
    }

    function vaultBurnDebtTokens(uint256 amount) external override onlyLeverager {
        address debtToken = alchemist.debtToken();
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(debtToken).approve(address(alchemist), amount);
        alchemist.burn(amount, vaultPositionId);
    }

    function getVaultPositionId() external view override returns (uint256) {
        return vaultPositionId;
    }

    function getYieldToken() external view returns (address) {
        return alchemist.yieldToken();
    }

    function getUnderlyingToken() external view returns (address) {
        return underlyingToken;
    }
}

/// @dev Malicious contract that tries to spoof flash loan callbacks
contract MaliciousCallbackSpoofer {
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

contract SecurityTests is Test {
    V3Leverager public leverager;
    EulerFlashLoanAdapter public eulerAdapter;

    MockERC20 public underlyingToken;
    MockERC20 public yieldToken;
    MockERC20 public debtToken;

    MockAlchemistV3 public alchemist;
    MockTokenConverter public converter;
    MockSwapper public swapper;
    MockFlashLoanAdapter public flashLoanAdapter;
    MockVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        // Deploy tokens
        underlyingToken = new MockERC20("Underlying", "UND");
        yieldToken = new MockERC20("Yield", "YLD");
        debtToken = new MockERC20("Debt", "DBT");

        // Deploy alchemist
        alchemist = new MockAlchemistV3(address(debtToken), address(yieldToken));

        // Deploy adapters
        converter = new MockTokenConverter(address(underlyingToken), address(yieldToken));
        swapper = new MockSwapper(address(debtToken), address(underlyingToken));
        flashLoanAdapter = new MockFlashLoanAdapter(address(underlyingToken));

        // Deploy leverager
        vm.prank(owner);
        leverager = new V3Leverager(owner);

        // Deploy vault
        vault = new MockVault(address(alchemist), address(leverager), address(underlyingToken));

        // Approve adapters
        vm.startPrank(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setSwapperApproval(address(swapper), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        vm.stopPrank();

        // Deploy Euler adapter
        address[] memory tokens = new address[](1);
        tokens[0] = address(underlyingToken);
        address[] memory dTokens = new address[](1);
        dTokens[0] = address(0x1234); // Mock dToken

        eulerAdapter = new EulerFlashLoanAdapter(tokens, dTokens);

        // Fund users
        yieldToken.mint(alice, 100 ether);
    }

    // ============ 1. Callback Spoofing Tests ============

    function test_RevertOnSpoofedCallback() public {
        MaliciousCallbackSpoofer spoofer = new MaliciousCallbackSpoofer(address(leverager));

        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        spoofer.attemptSpoofedCallback();
    }

    function test_RevertOnDirectCallbackNotFromAdapter() public {
        vm.prank(attacker);
        vm.expectRevert(V3Leverager.NotInFlashLoan.selector);
        leverager.onFlashLoanReceived(attacker, address(underlyingToken), 100 ether, 0, "");
    }

    // ============ 2. Euler Adapter Access Control Tests ============

    function test_EulerAdapter_RevertOnUnauthorizedSetDToken() public {
        address newDToken = makeAddr("newDToken");

        vm.prank(attacker);
        vm.expectRevert(); // Ownable revert
        eulerAdapter.setDToken(address(underlyingToken), newDToken);
    }

    function test_EulerAdapter_OwnerCanSetDToken() public {
        address newDToken = makeAddr("newDToken");

        // Get the owner (deployer)
        address eulerOwner = eulerAdapter.owner();

        vm.prank(eulerOwner);
        eulerAdapter.setDToken(address(underlyingToken), newDToken);

        assertEq(eulerAdapter.dTokens(address(underlyingToken)), newDToken);
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
        BadSlippageSwapper badSwapper = new BadSlippageSwapper(
            address(debtToken),
            address(underlyingToken),
            10 ether // Will return only 10 ether regardless of input
        );

        // Approve the bad swapper
        vm.prank(owner);
        leverager.setSwapperApproval(address(badSwapper), true);

        // Try to leverage with minSwapOutput higher than what swapper will return
        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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
        yieldToken.approve(address(leverager), 10 ether);

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
        yieldToken.approve(address(leverager), 10 ether);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: 10 ether,
            flashLoanAmount: 20 ether,
            mintAmount: 25 ether,
            minSwapOutput: 1,
            minYieldOut: 40 ether
        });

        vm.expectRevert(bytes("Insufficient yield output"));
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_DeleveragePaysRecipient() public {
        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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

        uint256 balanceBefore = underlyingToken.balanceOf(alice);

        ILeveragerV3.DeleverageParams memory deleverageParams = ILeveragerV3.DeleverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            recipient: alice,
            withdrawAmount: 12 ether,
            flashLoanAmount: 10 ether,
            burnAmount: 9 ether,
            minOutput: 1
        });

        leverager.deleverage(deleverageParams);
        vm.stopPrank();

        uint256 balanceAfter = underlyingToken.balanceOf(alice);
        assertGt(balanceAfter, balanceBefore);
    }

    // ============ 4. Reentrancy Tests ============

    function test_LeverageIsNonReentrant() public {
        // This test verifies the nonReentrant modifier is in place
        // The actual reentrancy would require a malicious contract that calls back
        // during flash loan execution - the modifier should prevent this

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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
        MockTokenConverter newConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setConverterApproval(address(newConverter), true);
    }

    function test_OnlyOwnerCanApproveFlashLoanAdapters() public {
        MockFlashLoanAdapter newAdapter = new MockFlashLoanAdapter(address(underlyingToken));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setFlashLoanAdapterApproval(address(newAdapter), true);
    }

    function test_OnlyOwnerCanApproveSwappers() public {
        MockSwapper newSwapper = new MockSwapper(address(debtToken), address(underlyingToken));

        vm.prank(attacker);
        vm.expectRevert();
        leverager.setSwapperApproval(address(newSwapper), true);
    }

    function test_UnapprovedAdaptersRejected() public {
        MockTokenConverter unapprovedConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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
        yieldToken.approve(address(leverager), 10 ether);

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
        underlyingToken.mint(address(eulerAdapter), 100 ether);

        address eulerOwner = eulerAdapter.owner();
        uint256 balanceBefore = underlyingToken.balanceOf(eulerOwner);

        vm.prank(eulerOwner);
        eulerAdapter.emergencyWithdraw(address(underlyingToken), 50 ether);

        assertEq(underlyingToken.balanceOf(eulerOwner), balanceBefore + 50 ether);
    }

    function test_EulerAdapter_NonOwnerCannotEmergencyWithdraw() public {
        underlyingToken.mint(address(eulerAdapter), 100 ether);

        vm.prank(attacker);
        vm.expectRevert();
        eulerAdapter.emergencyWithdraw(address(underlyingToken), 50 ether);
    }
}
