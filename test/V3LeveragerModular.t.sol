// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/leveragers/V3Leverager.sol";
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
        // 1:1 conversion for simplicity
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
        // 99% conversion (1% fee)
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
        // Mint tokens for flash loan
        MockERC20(_token).mint(address(this), amount);
        IERC20(_token).safeTransfer(recipient, amount);

        // Call recipient
        IFlashLoanCallback(recipient).onFlashLoanReceived(
            msg.sender,
            _token,
            amount,
            0, // no fee
            data
        );

        // Verify repayment
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
            // Create new position - pass 0 to indicate new position
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

// ============ Test Contract ============

contract V3LeveragerModularTest is Test {
    V3Leverager public leverager;

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
    address public bob = makeAddr("bob");

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

        // Deploy vault (needs leverager address)
        vault = new MockVault(address(alchemist), address(leverager), address(underlyingToken));

        // Approve adapters
        vm.startPrank(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setSwapperApproval(address(swapper), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        vm.stopPrank();

        // Fund users with yield tokens
        yieldToken.mint(alice, 100 ether);
        yieldToken.mint(bob, 100 ether);
    }

    // ============ Registry Tests ============

    function test_OwnerCanApproveConverter() public {
        MockTokenConverter newConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

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
        MockTokenConverter newConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.prank(alice);
        vm.expectRevert();
        leverager.setConverterApproval(address(newConverter), true);
    }

    function test_OwnerCanApproveFlashLoanAdapter() public {
        MockFlashLoanAdapter newAdapter = new MockFlashLoanAdapter(address(underlyingToken));

        assertFalse(leverager.isApprovedFlashLoanAdapter(address(newAdapter)));

        vm.prank(owner);
        leverager.setFlashLoanAdapterApproval(address(newAdapter), true);

        assertTrue(leverager.isApprovedFlashLoanAdapter(address(newAdapter)));
    }

    function test_OwnerCanApproveSwapper() public {
        MockSwapper newSwapper = new MockSwapper(address(debtToken), address(underlyingToken));

        assertFalse(leverager.isApprovedSwapper(address(newSwapper)));

        vm.prank(owner);
        leverager.setSwapperApproval(address(newSwapper), true);

        assertTrue(leverager.isApprovedSwapper(address(newSwapper)));
    }

    function test_BatchApprove() public {
        MockTokenConverter newConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));
        MockFlashLoanAdapter newAdapter = new MockFlashLoanAdapter(address(underlyingToken));
        MockSwapper newSwapper = new MockSwapper(address(debtToken), address(underlyingToken));

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

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), depositAmount);

        ILeveragerV3.LeverageParams memory params = ILeveragerV3.LeverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            depositAmount: depositAmount,
            flashLoanAmount: flashLoanAmount,
            mintAmount: mintAmount,
            minSwapOutput: 1, // Just need some output
            minYieldOut: 0
        });

        leverager.leverage(params);
        vm.stopPrank();

        // Verify position state
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());

        // Total collateral = deposit + flash loan converted to yield
        assertEq(collateral, depositAmount + flashLoanAmount);
        assertEq(debt, mintAmount);
    }

    function test_LeverageRevertsWithUnapprovedConverter() public {
        MockTokenConverter unapprovedConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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

        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_LeverageRevertsWithUnapprovedFlashLoanAdapter() public {
        MockFlashLoanAdapter unapprovedAdapter = new MockFlashLoanAdapter(address(underlyingToken));

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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

        vm.expectRevert(V3Leverager.UnapprovedFlashLoanAdapter.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_LeverageRevertsWithUnapprovedSwapper() public {
        MockSwapper unapprovedSwapper = new MockSwapper(address(debtToken), address(underlyingToken));

        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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

        vm.expectRevert(V3Leverager.UnapprovedSwapper.selector);
        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_LeverageWithZeroDeposit() public {
        vm.startPrank(alice);

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

        leverager.leverage(params);
        vm.stopPrank();

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 20 ether); // Only flash loan
        assertEq(debt, 25 ether);
    }

    // ============ Deleverage Tests ============

    function test_DeleverageWithApprovedAdapters() public {
        // First leverage to create a position
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

        // Now deleverage
        ILeveragerV3.DeleverageParams memory deleverageParams = ILeveragerV3.DeleverageParams({
            vault: address(vault),
            converter: address(converter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            recipient: alice,
            withdrawAmount: 15 ether,
            flashLoanAmount: 10 ether,
            burnAmount: 9 ether,
            minOutput: 1
        });

        leverager.deleverage(deleverageParams);
        vm.stopPrank();

        // Position should be reduced
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 30 ether - 15 ether); // Withdrew 15
        assertLt(debt, 25 ether); // Some debt was burned
    }

    function test_DeleverageRevertsWithUnapprovedConverter() public {
        MockTokenConverter unapprovedConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.startPrank(alice);

        ILeveragerV3.DeleverageParams memory params = ILeveragerV3.DeleverageParams({
            vault: address(vault),
            converter: address(unapprovedConverter),
            flashLoanAdapter: address(flashLoanAdapter),
            swapper: address(swapper),
            recipient: alice,
            withdrawAmount: 10 ether,
            flashLoanAmount: 10 ether,
            burnAmount: 10 ether,
            minOutput: 1
        });

        vm.expectRevert(V3Leverager.UnapprovedConverter.selector);
        leverager.deleverage(params);
        vm.stopPrank();
    }

    // ============ Multi-Vault Tests ============

    function test_SameLeveragerServesMultipleVaults() public {
        // Deploy second vault
        MockVault vault2 = new MockVault(address(alchemist), address(leverager), address(underlyingToken));

        // Alice leverages vault 1
        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 10 ether);

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
        leverager.leverage(params1);
        vm.stopPrank();

        // Bob leverages vault 2
        vm.startPrank(bob);
        yieldToken.approve(address(leverager), 15 ether);

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
        leverager.leverage(params2);
        vm.stopPrank();

        // Verify both vaults have positions
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
        MockFlashLoanAdapter altFlashLoan = new MockFlashLoanAdapter(address(underlyingToken));
        MockSwapper altSwapper = new MockSwapper(address(debtToken), address(underlyingToken));

        // Approve them
        vm.startPrank(owner);
        leverager.setFlashLoanAdapterApproval(address(altFlashLoan), true);
        leverager.setSwapperApproval(address(altSwapper), true);
        vm.stopPrank();

        // Use original adapters
        vm.startPrank(alice);
        yieldToken.approve(address(leverager), 20 ether);

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
        leverager.leverage(params1);

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
        leverager.leverage(params2);
        vm.stopPrank();

        // Both operations should have succeeded
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(vault.getVaultPositionId());
        assertEq(collateral, 30 ether); // 15 + 15
        assertEq(debt, 24 ether); // 12 + 12
    }

    // ============ Events Tests ============

    function test_EmitsLeverageExecutedEvent() public {
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
            minYieldOut: 0
        });

        vm.expectEmit(true, true, false, false);
        emit ILeveragerV3.LeverageExecuted(
            address(vault),
            alice,
            10 ether,
            20 ether,
            30 ether,
            25 ether
        );

        leverager.leverage(params);
        vm.stopPrank();
    }

    function test_EmitsConverterApprovalEvent() public {
        MockTokenConverter newConverter = new MockTokenConverter(address(underlyingToken), address(yieldToken));

        vm.expectEmit(true, false, false, true);
        emit ILeveragerV3.ConverterApprovalSet(address(newConverter), true);

        vm.prank(owner);
        leverager.setConverterApproval(address(newConverter), true);
    }
}
