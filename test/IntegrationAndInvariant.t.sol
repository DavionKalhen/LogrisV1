// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";
import "../src/LeveragedVault.sol";
import "../src/leveragers/V3Leverager.sol";
import "../src/interfaces/ILeveragerV3.sol";
import "../src/interfaces/ITokenConverter.sol";
import "../src/interfaces/ISwapper.sol";
import "../src/interfaces/flashloan/IFlashLoanAdapter.sol";
import "../src/interfaces/flashloan/IFlashLoanCallback.sol";

// ============ Full-Stack Mocks ============

contract IntMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract IntMockWETH is IntMockERC20 {
    constructor() IntMockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract IntMockPositionNFT {
    address public alchemist;
    uint256 private _currentTokenId;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(address => uint256[]) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    constructor(address _alchemist) { alchemist = _alchemist; }

    function mint(address to) external returns (uint256) {
        require(msg.sender == alchemist, "Only alchemist");
        uint256 tokenId = ++_currentTokenId;
        _owners[tokenId] = to;
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
        return tokenId;
    }

    function ownerOf(uint256 tokenId) external view returns (address) { return _owners[tokenId]; }
    function balanceOf(address owner) external view returns (uint256) { return _balances[owner]; }
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        return _ownedTokens[owner][index];
    }
    function transferFrom(address from, address to, uint256 tokenId) external {
        _owners[tokenId] = to;
        // Simplified enumerable bookkeeping
        uint256 fromIdx = _ownedTokensIndex[tokenId];
        uint256 lastIdx = _ownedTokens[from].length - 1;
        if (fromIdx != lastIdx) {
            uint256 lastId = _ownedTokens[from][lastIdx];
            _ownedTokens[from][fromIdx] = lastId;
            _ownedTokensIndex[lastId] = fromIdx;
        }
        _ownedTokens[from].pop();
        _balances[from] -= 1;
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
    }
}

/// @dev Full AlchemistV3 mock that supports the complete leverage/deleverage flow
contract IntMockAlchemistV3 {
    address public yieldTokenAddr;
    address public debtTokenAddr;
    IntMockPositionNFT public positionNFT;

    uint256 public depositCapVal = type(uint256).max;
    uint256 public totalDepositedVal;
    uint256 public minCollateralizationVal = 2e18; // 200% for simpler math

    mapping(uint256 => uint256) public posCollateral;
    mapping(uint256 => uint256) public posDebt;
    mapping(uint256 => mapping(address => uint256)) public mintAllowances;

    bool public depositsPausedVal;
    bool public loansPausedVal;

    constructor(address _yieldToken, address _debtToken) {
        yieldTokenAddr = _yieldToken;
        debtTokenAddr = _debtToken;
        positionNFT = new IntMockPositionNFT(address(this));
    }

    function alchemistPositionNFT() external view returns (address) { return address(positionNFT); }
    function depositsPaused() external view returns (bool) { return depositsPausedVal; }
    function loansPaused() external view returns (bool) { return loansPausedVal; }
    function depositCap() external view returns (uint256) { return depositCapVal; }
    function getTotalDeposited() external view returns (uint256) { return totalDepositedVal; }
    function minimumCollateralization() external view returns (uint256) { return minCollateralizationVal; }
    function yieldToken() external view returns (address) { return yieldTokenAddr; }
    function debtToken() external view returns (address) { return debtTokenAddr; }

    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) { return amount; }
    function convertUnderlyingTokensToYield(uint256 amount) external pure returns (uint256) { return amount; }
    function normalizeDebtTokensToUnderlying(uint256 amount) external pure returns (uint256) { return amount; }
    function normalizeUnderlyingTokensToDebt(uint256 amount) external pure returns (uint256) { return amount; }

    function getMaxBorrowable(uint256 posId) external view returns (uint256) {
        uint256 maxDebt = posCollateral[posId] * 1e18 / minCollateralizationVal;
        return maxDebt > posDebt[posId] ? maxDebt - posDebt[posId] : 0;
    }

    function getCDP(uint256 posId) external view returns (uint256, uint256, uint256) {
        return (posCollateral[posId], posDebt[posId], 0);
    }

    function approveMint(uint256 posId, address spender, uint256 amount) external {
        mintAllowances[posId][spender] = amount;
    }

    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256) {
        ERC20(yieldTokenAddr).transferFrom(msg.sender, address(this), amount);
        if (recipientId == 0) {
            positionNFT.mint(recipient);
            recipientId = 1; // simplified first position
        }
        posCollateral[recipientId] += amount;
        totalDepositedVal += amount;
        return 0;
    }

    function withdraw(uint256 amount, address recipient, uint256 posId) external returns (uint256) {
        require(posCollateral[posId] >= amount, "Insufficient collateral");
        posCollateral[posId] -= amount;
        totalDepositedVal -= amount;
        ERC20(yieldTokenAddr).transfer(recipient, amount);
        return amount;
    }

    function mint(uint256 posId, uint256 amount, address recipient) external {
        uint256 maxDebt = posCollateral[posId] * 1e18 / minCollateralizationVal;
        require(posDebt[posId] + amount <= maxDebt, "Exceeds max debt");
        posDebt[posId] += amount;
        IntMockERC20(debtTokenAddr).mint(recipient, amount);
    }

    function burn(uint256 amount, uint256 posId) external returns (uint256) {
        ERC20(debtTokenAddr).transferFrom(msg.sender, address(this), amount);
        posDebt[posId] -= amount;
        return amount;
    }
}

/// @dev 1:1 converter for testing
contract IntMockConverter is ITokenConverter {
    using SafeERC20 for IERC20;
    address public override yieldToken;
    address public override underlyingToken;

    constructor(address _underlying, address _yield) {
        underlyingToken = _underlying;
        yieldToken = _yield;
    }

    function toYield(uint256 amount, address recipient, uint256 minYieldOut) external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), amount);
        IntMockERC20(yieldToken).mint(recipient, amount);
        require(amount >= minYieldOut, "Insufficient yield output");
        return amount;
    }

    function toUnderlying(uint256 amount, address recipient, uint256) external override returns (uint256) {
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        IntMockERC20(underlyingToken).mint(recipient, amount);
        return amount;
    }

    function previewToYield(uint256 amount) external pure override returns (uint256) { return amount; }
    function previewToUnderlying(uint256 amount) external pure override returns (uint256) { return amount; }
}

/// @dev Swapper with 1% fee
contract IntMockSwapper is ISwapper {
    using SafeERC20 for IERC20;
    address public debtToken;
    address public underlyingToken;

    constructor(address _debt, address _underlying) {
        debtToken = _debt;
        underlyingToken = _underlying;
    }

    function swapDebtToUnderlying(uint256 debtAmount, uint256, address recipient, bytes calldata)
        external override returns (uint256) {
        IERC20(debtToken).transferFrom(msg.sender, address(this), debtAmount);
        uint256 output = debtAmount * 99 / 100;
        IntMockERC20(underlyingToken).mint(recipient, output);
        return output;
    }

    function swapUnderlyingToDebt(uint256 underlyingAmount, uint256, address recipient, bytes calldata)
        external override returns (uint256) {
        IERC20(underlyingToken).transferFrom(msg.sender, address(this), underlyingAmount);
        uint256 output = underlyingAmount * 99 / 100;
        IntMockERC20(debtToken).mint(recipient, output);
        return output;
    }

    function previewSwapDebtToUnderlying(uint256 d) external pure override returns (uint256, uint256) { return (d*99/100, d*94/100); }
    function previewSwapUnderlyingToDebt(uint256 u) external pure override returns (uint256, uint256) { return (u*99/100, u*94/100); }
    function getDebtToUnderlyingRate() external pure override returns (uint256) { return 0.99e18; }
    function getUnderlyingToDebtRate() external pure override returns (uint256) { return 0.99e18; }
    function getSwapFee() external pure override returns (uint256) { return 100; }
    function getSlippageTolerance() external pure override returns (uint256) { return 0; }
    function isSupportedPair(address, address) external pure override returns (bool) { return true; }
}

/// @dev Flash loan adapter that mints tokens (simulates real flash loan)
contract IntMockFlashLoan is IFlashLoanAdapter {
    using SafeERC20 for IERC20;

    function flashLoan(address token, uint256 amount, address recipient, bytes calldata data) external override {
        IntMockERC20(token).mint(address(this), amount);
        IERC20(token).safeTransfer(recipient, amount);
        IFlashLoanCallback(recipient).onFlashLoanReceived(msg.sender, token, amount, 0, data);
        require(IERC20(token).balanceOf(address(this)) >= amount, "Flash loan not repaid");
        emit FlashLoanExecuted(token, amount, 0, recipient);
    }

    function getFlashLoanFee(address, uint256) external pure override returns (uint256) { return 0; }
    function isTokenSupported(address) external pure override returns (bool) { return true; }
    function maxFlashLoan(address) external pure override returns (uint256) { return type(uint256).max; }
    function getProvider() external view override returns (address) { return address(this); }
}

// ============ Helper: deploy impl + clone + initialize ============

function _deployVaultClone(
    address _yieldToken,
    address _underlyingAndWeth,
    address _alchemist,
    address _leverager,
    address _converter,
    address _flashLoan,
    address _swapper,
    address _owner
) returns (LeveragedVault) {
    LeveragedVault impl = new LeveragedVault();
    LeveragedVault vault = LeveragedVault(payable(Clones.clone(address(impl))));
    vault.initialize(
        _yieldToken, _underlyingAndWeth,
        _alchemist, _leverager,
        100, 200,
        _converter, _flashLoan, _swapper,
        _underlyingAndWeth,
        _owner
    );
    return vault;
}

// ============ Integration Test ============

contract FullIntegrationTest is Test {
    IntMockWETH public weth;
    IntMockERC20 public yieldToken;
    IntMockERC20 public debtToken;
    IntMockAlchemistV3 public alchemist;
    IntMockConverter public converter;
    IntMockSwapper public swapper;
    IntMockFlashLoan public flashLoanAdapter;
    V3Leverager public leverager;
    LeveragedVault public vault;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        weth = new IntMockWETH();
        yieldToken = new IntMockERC20("Yield", "YLD");
        debtToken = new IntMockERC20("Debt", "DBT");
        alchemist = new IntMockAlchemistV3(address(yieldToken), address(debtToken));
        converter = new IntMockConverter(address(weth), address(yieldToken));
        swapper = new IntMockSwapper(address(debtToken), address(weth));
        flashLoanAdapter = new IntMockFlashLoan();

        vm.startPrank(owner);
        leverager = new V3Leverager(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoanAdapter), true);
        leverager.setSwapperApproval(address(swapper), true);

        vault = _deployVaultClone(
            address(yieldToken), address(weth),
            address(alchemist), address(leverager),
            address(converter), address(flashLoanAdapter), address(swapper),
            owner
        );
        vm.stopPrank();

        // Fund users
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ============ Full Deposit → Leverage → Withdraw Cycle ============

    function test_FullCycle_DepositLeverageWithdraw() public {
        uint256 depositAmount = 10 ether;

        // 1. Alice deposits ETH
        vm.prank(alice);
        uint256 shares = vault.depositUnderlying{value: depositAmount}();
        assertEq(shares, depositAmount * 1000, "Should get 1000:1 shares on first deposit (offset=3)");
        assertEq(vault.getDepositPoolBalance(), depositAmount, "Pool should hold deposit");

        // 2. Leverage the deposit (no flash loan for simplicity, just deposit to Alchemist)
        vm.prank(alice);
        vault.leverage(depositAmount, 0, depositAmount, 0, 0);

        // Verify position was created
        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should exist");

        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertEq(collateral, depositAmount, "Collateral should equal deposit");
        assertEq(debt, 0, "No debt without flash loan");
        assertEq(vault.getDepositPoolBalance(), 0, "Pool should be drained");

        // 3. Withdraw (simple case, no debt to unwind)
        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlying(shares, 0, 0, 0);
        assertEq(withdrawn, depositAmount, "Should withdraw full deposit");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares");
    }

    function test_FullCycle_WithFlashLoanLeverage() public {
        uint256 depositAmount = 10 ether;

        // 1. Alice deposits WETH
        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        // 2. Leverage with flash loan
        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 underlyingDepositMin = totalDeposit * 9900 / 10000;
        uint256 debtTradeMin = mintAmount * 9800 / 10000;

        vm.prank(alice);
        vault.leverage(
            depositAmount,
            flashLoanAmount,
            underlyingDepositMin,
            mintAmount,
            debtTradeMin
        );

        uint256 posId = vault.getVaultPositionId();
        (uint256 collateral, uint256 debt,) = alchemist.getCDP(posId);
        assertEq(collateral, totalDeposit, "Collateral = deposit + flash loan");
        assertEq(debt, mintAmount, "Debt should equal mint amount");

        // 3. Verify vault share value still reasonable
        uint256 shareValue = vault.convertSharesToUnderlyingTokens(vault.balanceOf(alice));
        assertGt(shareValue, 0, "Share value should be positive");
    }

    function test_MultiUser_DepositAndLeverage() public {
        // 1. Alice deposits 10 ETH
        vm.prank(alice);
        uint256 aliceShares = vault.depositUnderlying{value: 10 ether}();

        // 2. Bob deposits 5 ETH
        vm.prank(bob);
        uint256 bobShares = vault.depositUnderlying{value: 5 ether}();

        assertEq(aliceShares, 10_000 ether);
        assertEq(bobShares, 5_000 ether);
        assertEq(vault.totalSupply(), 15_000 ether);

        // 3. Leverage entire pool (no flash loan)
        vm.prank(alice);
        vault.leverage(15 ether, 0, 15 ether, 0, 0);

        // 4. Both users' shares should still reflect their proportional ownership
        uint256 aliceValue = vault.convertSharesToUnderlyingTokens(aliceShares);
        uint256 bobValue = vault.convertSharesToUnderlyingTokens(bobShares);

        assertApproxEqAbs(aliceValue, 10 ether, 1, "Alice should have ~10 ETH value");
        assertApproxEqAbs(bobValue, 5 ether, 1, "Bob should have ~5 ETH value");
    }

    // ============ leverageAtomic Tests ============

    function test_LeverageAtomic_UsesDefaultSlippage() public {
        uint256 depositAmount = 10 ether;

        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        vault.leverageAtomic(depositAmount, 100, 200);

        uint256 posId = vault.getVaultPositionId();
        assertGt(posId, 0, "Position should be created");

        (uint256 collateral,,) = alchemist.getCDP(posId);
        assertGt(collateral, 0, "Should have collateral");
    }

    function test_WithdrawUnderlyingAtomic_Works() public {
        uint256 depositAmount = 10 ether;

        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        uint256 shares = vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        vm.prank(alice);
        uint256 withdrawn = vault.withdrawUnderlyingAtomic(shares, 100, 200);

        assertApproxEqAbs(withdrawn, depositAmount, 1, "Should withdraw full amount");
        assertEq(vault.balanceOf(alice), 0, "Should have 0 shares");
    }

    // ============ Slippage Enforcement Tests ============

    function test_SlippageEnforcement_RejectsZeroDebtSlippage() public {
        uint256 depositAmount = 10 ether;

        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;

        vm.prank(alice);
        vm.expectRevert(LeveragedVault.SwapSlippageBelowMinimum.selector);
        vault.leverage(depositAmount, flashLoanAmount, totalDeposit, 3 ether, 0);
    }

    function test_SlippageEnforcement_OnlyChecksDebtSwap() public {
        uint256 depositAmount = 10 ether;

        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 validDebtTradeMin = mintAmount * 9800 / 10000;
        uint256 validDepositMin = totalDeposit;

        vm.prank(alice);
        vault.leverage(depositAmount, flashLoanAmount, validDepositMin, mintAmount, validDebtTradeMin);

        assertGt(vault.getVaultPositionId(), 0, "Leverage should succeed");
    }

    function test_SlippageEnforcement_AcceptsValidSlippage() public {
        uint256 depositAmount = 10 ether;

        weth.mint(alice, depositAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), depositAmount);
        vault.depositUnderlying(depositAmount);
        vm.stopPrank();

        uint256 flashLoanAmount = 2 ether;
        uint256 totalDeposit = depositAmount + flashLoanAmount;
        uint256 mintAmount = 3 ether;
        uint256 validDebtTradeMin = mintAmount * 9800 / 10000;

        vm.prank(alice);
        vault.leverage(depositAmount, flashLoanAmount, totalDeposit, mintAmount, validDebtTradeMin);

        assertGt(vault.getVaultPositionId(), 0, "Leverage should succeed");
    }

    // ============ Admin Function Validation Tests ============

    function test_AdaptersAreSet() public view {
        assertEq(vault.converter(), address(converter), "Converter should be set at initialization");
        assertEq(vault.flashLoanAdapter(), address(flashLoanAdapter), "Flash loan adapter should be set at initialization");
        assertEq(vault.swapper(), address(swapper), "Swapper should be set at initialization");
    }

    // ============ Emergency Sweep Tests ============

    function test_EmergencySweep_WorksForOwner() public {
        IntMockERC20 randomToken = new IntMockERC20("Random", "RND");
        randomToken.mint(address(vault), 50 ether);

        vm.prank(owner);
        vault.emergencySweepToken(address(randomToken), 50 ether, owner);

        assertEq(randomToken.balanceOf(owner), 50 ether, "Owner should receive swept tokens");
        assertEq(randomToken.balanceOf(address(vault)), 0, "Vault should have 0 random tokens");
    }

    function test_EmergencySweep_RevertsForNonOwner() public {
        IntMockERC20 randomToken = new IntMockERC20("Random", "RND");
        vm.prank(alice);
        vm.expectRevert();
        vault.emergencySweepToken(address(randomToken), 1 ether, alice);
    }

    function test_EmergencySweep_RejectsZeroRecipient() public {
        IntMockERC20 randomToken = new IntMockERC20("Random", "RND");
        vm.prank(owner);
        vm.expectRevert(LeveragedVault.InvalidRecipient.selector);
        vault.emergencySweepToken(address(randomToken), 1 ether, address(0));
    }

    // ============ Receive ETH Test ============

    function test_VaultCanReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertTrue(success, "Vault should accept ETH");
    }

    // ============ Parameterless View Function Tests ============

    function test_GetLeverageParameters_Parameterless() public {
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(address(vault), 10 ether);
        vault.depositUnderlying(10 ether);
        vm.stopPrank();

        (uint256 clampedDeposit1,,,,) = vault.getLeverageParameters(10 ether);
        (uint256 clampedDeposit2,,,,) = vault.getLeverageParameters(10 ether, 100, 200);

        assertEq(clampedDeposit1, clampedDeposit2, "Parameterless should match explicit with defaults");
    }

    // ============ Slippage Setter Tests ============

    function test_SetSlippageParameters() public {
        vm.prank(owner);
        vault.setSlippageParameters(50, 150);

        assertEq(vault.underlyingSlippageBasisPoints(), 50);
        assertEq(vault.debtSlippageBasisPoints(), 150);
    }

    function test_SetSlippageParameters_RejectsExcessive() public {
        vm.prank(owner);
        vm.expectRevert(LeveragedVault.SlippageTooHigh.selector);
        vault.setSlippageParameters(10000, 200);
    }
}

// ============ Invariant Test ============

/// @notice Handler for invariant testing - executes random deposit/withdraw operations
contract VaultHandler is Test {
    LeveragedVault public vault;
    IntMockWETH public weth;
    address[] public actors;

    constructor(LeveragedVault _vault, IntMockWETH _weth) {
        vault = _vault;
        weth = _weth;
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        // Fund actors
        for (uint i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 1000 ether);
        }
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e12, 100 ether);

        vm.prank(actor);
        vault.depositUnderlying{value: amount}();
    }

    function withdraw(uint256 actorSeed, uint256 shareFraction) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;

        shareFraction = bound(shareFraction, 1, 100);
        uint256 shares = balance * shareFraction / 100;
        if (shares == 0) return;

        vm.prank(actor);
        vault.withdrawUnderlying(shares, 0, 0, 0);
    }
}

contract ShareValueInvariantTest is Test {
    IntMockWETH public weth;
    IntMockERC20 public yieldToken;
    IntMockERC20 public debtToken;
    IntMockAlchemistV3 public alchemist;
    LeveragedVault public vault;
    VaultHandler public handler;

    function setUp() public {
        weth = new IntMockWETH();
        yieldToken = new IntMockERC20("Yield", "YLD");
        debtToken = new IntMockERC20("Debt", "DBT");
        alchemist = new IntMockAlchemistV3(address(yieldToken), address(debtToken));

        IntMockConverter converter = new IntMockConverter(address(weth), address(yieldToken));
        IntMockFlashLoan flashLoan = new IntMockFlashLoan();
        IntMockSwapper swapper = new IntMockSwapper(address(debtToken), address(weth));

        address owner = makeAddr("owner");
        vm.startPrank(owner);
        V3Leverager leverager = new V3Leverager(owner);
        leverager.setConverterApproval(address(converter), true);
        leverager.setFlashLoanAdapterApproval(address(flashLoan), true);
        leverager.setSwapperApproval(address(swapper), true);

        vault = _deployVaultClone(
            address(yieldToken), address(weth),
            address(alchemist), address(leverager),
            address(converter), address(flashLoan), address(swapper),
            owner
        );
        vm.stopPrank();

        handler = new VaultHandler(vault, weth);
        targetContract(address(handler));
    }

    /// @notice Total share value should always equal total assets (pool balance when no Alchemist position)
    function invariant_TotalShareValueEqualsPoolBalance() public view {
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply == 0) return;

        uint256 totalAssets = vault.totalAssets();
        uint256 poolBalance = vault.getDepositPoolBalance();

        if (vault.vaultPositionId() == 0) {
            assertEq(totalAssets, poolBalance, "Total assets must equal pool balance without position");
        }
    }

    /// @notice Total supply should never be negative (obvious but validates no underflow)
    function invariant_TotalSupplyNonNegative() public view {
        assertLe(vault.totalSupply(), 1000 ether * 3 * 1000, "Total supply should be bounded");
    }

    /// @notice Pool balance should be consistent with deposits minus withdrawals
    function invariant_PoolBalanceConsistent() public view {
        uint256 poolBalance = vault.getDepositPoolBalance();
        uint256 wethBalance = weth.balanceOf(address(vault));
        assertEq(poolBalance, wethBalance, "Pool balance should equal WETH balance");
    }
}
