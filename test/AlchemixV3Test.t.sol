// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/AlchemixV3DebtAdapter.sol";
import "../src/leveragers/BalancerCurveLeverager.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Import Account struct directly
import { Account } from "../alchemix-v3/src/interfaces/IAlchemistV3.sol";

// Mock contracts for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
    }
    
    function name() external view returns (string memory) {
        return _name;
    }
    
    function symbol() external view returns (string memory) {
        return _symbol;
    }
    
    function decimals() external pure returns (uint8) {
        return 18;
    }
    
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }
    
    function transfer(address to, uint256 amount) external override returns (bool) {
        address owner = msg.sender;
        _transfer(owner, to, amount);
        return true;
    }
    
    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }
    
    function approve(address spender, uint256 amount) external override returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }
    
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        
        _allowances[owner][spender] = amount;
    }
    
    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
}

contract MockAlchemistV3 is IAlchemistV3 {
    address public override debtToken;
    address public override underlyingToken;
    address public override yieldToken;
    uint256 public override minimumCollateralization = 2 * 1e18; // 200%
    address private _positionNFT;
    
    mapping(uint256 => uint256) private _collateralBalances;
    mapping(uint256 => uint256) private _debtBalances;
    
    constructor(address debtToken_, address underlyingToken_, address yieldToken_, address positionNFT_) {
        debtToken = debtToken_;
        underlyingToken = underlyingToken_;
        yieldToken = yieldToken_;
        _positionNFT = positionNFT_;
    }
    
    function alchemistPositionNFT() external view override returns (address) {
        return _positionNFT;
    }
    
    function deposit(uint256 amount, address recipient, uint256 recipientId) external override returns (uint256) {
        // Transfer the tokens from the sender to this contract
        bool success = IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        
        // Update collateral balance
        _collateralBalances[recipientId] += amount;
        
        return amount;
    }
    
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external override returns (uint256) {
        require(_collateralBalances[tokenId] >= amount, "Insufficient collateral");
        
        // Update collateral balance
        _collateralBalances[tokenId] -= amount;
        
        // Transfer tokens to recipient
        bool success = IERC20(yieldToken).transfer(recipient, amount);
        require(success, "Transfer failed");
        
        return amount;
    }
    
    function mint(uint256 tokenId, uint256 amount, address recipient) external override {
        uint256 collateral = _collateralBalances[tokenId];
        uint256 newDebt = _debtBalances[tokenId] + amount;
        
        // Check if there's enough collateral
        require(collateral * 1e18 / newDebt >= minimumCollateralization, "Undercollateralized");
        
        // Update debt
        _debtBalances[tokenId] = newDebt;
        
        // Transfer debt tokens
        bool success = IERC20(debtToken).transfer(recipient, amount);
        require(success, "Transfer failed");
    }
    
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external override {
        // Call the mint function directly
        this.mint(tokenId, amount, recipient);
    }
    
    function burn(uint256 amount, uint256 recipientId) external override returns (uint256) {
        require(_debtBalances[recipientId] >= amount, "Insufficient debt");
        
        // Transfer debt tokens from sender
        bool success = IERC20(debtToken).transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer failed");
        
        // Update debt
        _debtBalances[recipientId] -= amount;
        
        return amount;
    }
    
    function approveMint(uint256 tokenId, address spender, uint256 amount) external override {
        // No need to implement for this test
    }
    
    function getCDP(uint256 tokenId) external view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        return (_collateralBalances[tokenId], _debtBalances[tokenId], 0);
    }
    
    // Other required functions from the interface - implement empty versions as needed for tests
    function poke(uint256) external override {}
    function repay(uint256, uint256) external override returns (uint256) { return 0; }
    function liquidate(uint256) external override returns (uint256, uint256, uint256) { return (0, 0, 0); }
    function batchLiquidate(uint256[] memory) external override returns (uint256, uint256, uint256) { return (0, 0, 0); }
    function redeem(uint256) external override {}
    function resetMintAllowances(uint256) external override {}
    function setPendingAdmin(address) external override {}
    function setGuardian(address, bool) external override {}
    function acceptAdmin() external override {}
    function setDepositCap(uint256) external override {}
    function setTokenAdapter(address) external override {}
    function setMinimumCollateralization(uint256) external override {}
    function setProtocolFeeReceiver(address) external override {}
    function setProtocolFee(uint256) external override {}
    function setLiquidatorFee(uint256) external override {}
    function setTransmuter(address) external override {}
    function setGlobalMinimumCollateralization(uint256) external override {}
    function setCollateralizationLowerBound(uint256) external override {}
    function pauseDeposits(bool) external override {}
    function pauseLoans(bool) external override {}
    function setAlchemistFeeVault(address) external override {}
    function version() external view override returns (string memory) { return "3.0.0"; }
    function admin() external view override returns (address) { return address(0); }
    function depositCap() external view override returns (uint256) { return type(uint256).max; }
    function guardians(address) external view override returns (bool) { return false; }
    function blocksPerYear() external view override returns (uint256) { return 2_628_000; }
    function cumulativeEarmarked() external view override returns (uint256) { return 0; }
    function lastEarmarkBlock() external view override returns (uint256) { return 0; }
    function lastRedemptionBlock() external view override returns (uint256) { return 0; }
    function totalDebt() external view override returns (uint256) { return 0; }
    function totalSyntheticsIssued() external view override returns (uint256) { return 0; }
    function protocolFee() external view override returns (uint256) { return 0; }
    function liquidatorFee() external view override returns (uint256) { return 0; }
    function underlyingConversionFactor() external view override returns (uint256) { return 1e18; }
    function protocolFeeReceiver() external view override returns (address) { return address(0); }
    function depositsPaused() external view override returns (bool) { return false; }
    function loansPaused() external view override returns (bool) { return false; }
    function pendingAdmin() external view override returns (address) { return address(0); }
    function tokenAdapter() external override returns (address) { return address(0); }
    function alchemistFeeVault() external view override returns (address) { return address(0); }
    function transmuter() external view override returns (address) { return address(0); }
    function globalMinimumCollateralization() external view override returns (uint256) { return 1.5e18; }
    function collateralizationLowerBound() external view override returns (uint256) { return 1.1e18; }
    function convertYieldTokensToDebt(uint256 amount) external view override returns (uint256) { return amount; }
    function convertYieldTokensToUnderlying(uint256 amount) external view override returns (uint256) { return amount; }
    function convertDebtTokensToYield(uint256 amount) external view override returns (uint256) { return amount; }
    function convertUnderlyingTokensToYield(uint256 amount) external view override returns (uint256) { return amount; }
    function calculateLiquidation(uint256, uint256, uint256, uint256, uint256, uint256) external view override returns (uint256, uint256, uint256) { return (0, 0, 0); }
    function normalizeUnderlyingTokensToDebt(uint256 amount) external view override returns (uint256) { return amount; }
    function normalizeDebtTokensToUnderlying(uint256 amount) external view override returns (uint256) { return amount; }
    function totalValue(uint256) external view override returns (uint256) { return 0; }
    function getTotalDeposited() external view override returns (uint256) { return 0; }
    function getMaxBorrowable(uint256) external view override returns (uint256) { return 0; }
    function getTotalUnderlyingValue() external view override returns (uint256) { return 0; }
    function mintAllowance(uint256, address) external view override returns (uint256) { return type(uint256).max; }
}

contract MockAlchemistV3Position {
    uint256 private _nextTokenId = 1;
    
    mapping(uint256 => address) private _owners;
    
    function mint(address owner) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _owners[tokenId] = owner;
        return tokenId;
    }
    
    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

contract AlchemixV3Test is Test {
    // Mock contracts
    MockERC20 public yieldToken;
    MockERC20 public underlyingToken;
    MockERC20 public debtToken;
    MockAlchemistV3Position public positionNFT;
    MockAlchemistV3 public alchemistV3;
    
    AlchemixV3DebtAdapter public adapter;
    BalancerCurveLeverager public leverager;
    
    address public alice = address(0x1);
    
    function setUp() public {
        // Deploy mock tokens
        yieldToken = new MockERC20("Yield Token", "yTKN");
        underlyingToken = new MockERC20("Underlying Token", "TKN");
        debtToken = new MockERC20("Debt Token", "dTKN");
        positionNFT = new MockAlchemistV3Position();
        
        // Deploy mock AlchemistV3
        alchemistV3 = new MockAlchemistV3(
            address(debtToken),
            address(underlyingToken),
            address(yieldToken),
            address(positionNFT)
        );
        
        // Mint tokens to AlchemistV3 for it to distribute
        debtToken.mint(address(alchemistV3), 10000 ether);
        
        // Deploy adapter and leverager
        adapter = new AlchemixV3DebtAdapter(address(alchemistV3));
        adapter.setYieldTokenUnderlyingPair(address(yieldToken), address(underlyingToken));
        
        leverager = new BalancerCurveLeverager(
            address(yieldToken),
            address(underlyingToken),
            address(debtToken),
            address(adapter)
        );
        
        // Deal some tokens to Alice
        underlyingToken.mint(alice, 1000 ether);
        yieldToken.mint(alice, 1000 ether);
        debtToken.mint(alice, 1000 ether);
        
        // Set approvals
        vm.startPrank(alice);
        underlyingToken.approve(address(leverager), type(uint256).max);
        yieldToken.approve(address(leverager), type(uint256).max);
        yieldToken.approve(address(alchemistV3), type(uint256).max);
        yieldToken.approve(address(adapter), type(uint256).max);
        debtToken.approve(address(leverager), type(uint256).max);
        debtToken.approve(address(adapter), type(uint256).max);
        
        // Approve adapter to mint from Alice's V3 position
        adapter.approveMint(address(leverager), type(uint256).max);
        vm.stopPrank();
    }
    
    function testCreatePosition() public {
        vm.startPrank(alice);
        
        // Verify position ID is created
        uint256 positionId = adapter.getOrCreatePositionId(alice);
        assertTrue(positionId > 0, "Position ID should be created");
        
        // Verify the same ID is returned on subsequent calls
        uint256 positionId2 = adapter.getOrCreatePositionId(alice);
        assertEq(positionId, positionId2, "Position ID should be the same");
        
        vm.stopPrank();
    }
    
    function testDeposit() public {
        vm.startPrank(alice);
        
        // Get initial balances
        uint256 initialYieldBalance = yieldToken.balanceOf(alice);
        
        // Create a position
        uint256 positionId = adapter.getOrCreatePositionId(alice);
        
        // Deposit yield tokens
        uint256 depositAmount = 100 ether;
        adapter.depositUnderlying(address(yieldToken), depositAmount, alice, 0);
        
        // Verify collateral is recorded
        (uint256 collateral, ,) = alchemistV3.getCDP(positionId);
        assertEq(collateral, depositAmount, "Collateral should match deposit amount");
        
        // Verify balances changed appropriately
        assertEq(yieldToken.balanceOf(alice), initialYieldBalance - depositAmount, "Yield token balance should decrease");
        
        vm.stopPrank();
    }
    
    function testMint() public {
        vm.startPrank(alice);
        
        // First deposit collateral
        uint256 depositAmount = 100 ether;
        uint256 positionId = adapter.getOrCreatePositionId(alice);
        adapter.depositUnderlying(address(yieldToken), depositAmount, alice, 0);
        
        // Get initial debt token balance
        uint256 initialDebtBalance = debtToken.balanceOf(alice);
        
        // Mint debt tokens
        uint256 mintAmount = 25 ether; // With 200% collateralization, can mint up to 50 ETH against 100 ETH collateral
        adapter.mint(mintAmount, alice);
        
        // Verify debt is recorded
        (, uint256 debt, ) = alchemistV3.getCDP(positionId);
        assertEq(debt, mintAmount, "Debt should match mint amount");
        
        // Verify balances changed appropriately
        assertEq(debtToken.balanceOf(alice), initialDebtBalance + mintAmount, "Debt token balance should increase");
        
        vm.stopPrank();
    }
    
    function testBurn() public {
        vm.startPrank(alice);
        
        // First deposit and mint
        uint256 depositAmount = 100 ether;
        uint256 mintAmount = 25 ether;
        uint256 positionId = adapter.getOrCreatePositionId(alice);
        
        adapter.depositUnderlying(address(yieldToken), depositAmount, alice, 0);
        adapter.mint(mintAmount, alice);
        
        // Get initial debt token balance
        uint256 initialDebtBalance = debtToken.balanceOf(alice);
        
        // Burn debt tokens
        uint256 burnAmount = 10 ether;
        adapter.burn(burnAmount, alice);
        
        // Verify debt is reduced
        (, uint256 debt, ) = alchemistV3.getCDP(positionId);
        assertEq(debt, 15 ether, "Debt should be reduced by burn amount");
        
        // Verify balances changed appropriately
        assertEq(debtToken.balanceOf(alice), initialDebtBalance - burnAmount, "Debt token balance should decrease");
        
        vm.stopPrank();
    }
    
    function testWithdraw() public {
        vm.startPrank(alice);
        
        // First deposit
        uint256 depositAmount = 100 ether;
        uint256 positionId = adapter.getOrCreatePositionId(alice);
        adapter.depositUnderlying(address(yieldToken), depositAmount, alice, 0);
        
        // Get initial yield token balance
        uint256 initialYieldBalance = yieldToken.balanceOf(alice);
        
        // Withdraw yield tokens
        uint256 withdrawAmount = 50 ether;
        adapter.withdrawUnderlyingFrom(alice, address(yieldToken), withdrawAmount, alice, 0);
        
        // Verify collateral is reduced
        (uint256 collateral, ,) = alchemistV3.getCDP(positionId);
        assertEq(collateral, 50 ether, "Collateral should be reduced by withdraw amount");
        
        // Verify balances changed appropriately
        assertEq(yieldToken.balanceOf(alice), initialYieldBalance + withdrawAmount, "Yield token balance should increase");
        
        vm.stopPrank();
    }
} 