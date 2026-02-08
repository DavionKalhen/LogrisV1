// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import "../src/LeveragedVault.sol";
import "lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            allowance[from][msg.sender] = currentAllowance - amount;
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

contract MockAlchemistV3Units {
    uint256 public depositCapAmount;
    uint256 public totalDepositedAmount;
    uint256 public minimumCollateralization;
    uint256 public yieldToUnderlyingRate;

    uint256 public collateralAmount;
    uint256 public debtAmount;

    constructor(uint256 _yieldToUnderlyingRate, uint256 _minimumCollateralization) {
        yieldToUnderlyingRate = _yieldToUnderlyingRate;
        minimumCollateralization = _minimumCollateralization;
    }

    function setDepositCap(uint256 amount) external {
        depositCapAmount = amount;
    }

    function setTotalDeposited(uint256 amount) external {
        totalDepositedAmount = amount;
    }

    function setCDP(uint256 collateral, uint256 debt) external {
        collateralAmount = collateral;
        debtAmount = debt;
    }

    function depositCap() external view returns (uint256) {
        return depositCapAmount;
    }

    function getTotalDeposited() external view returns (uint256) {
        return totalDepositedAmount;
    }

    function getMaxBorrowable(uint256) external pure returns (uint256) {
        return 0;
    }

    function getCDP(uint256) external view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        return (collateralAmount, debtAmount, 0);
    }

    function normalizeDebtTokensToUnderlying(uint256 amount) external pure returns (uint256) {
        return amount;
    }
    function normalizeUnderlyingTokensToDebt(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external view returns (uint256) {
        return amount * yieldToUnderlyingRate / 1e18;
    }

    function convertUnderlyingTokensToYield(uint256 amount) external view returns (uint256) {
        return amount * 1e18 / yieldToUnderlyingRate;
    }
}

contract UnitMismatchTests is Test {
    using stdStorage for StdStorage;

    MockERC20 private underlying;
    MockERC20 private yieldToken;
    MockAlchemistV3Units private alchemist;
    LeveragedVault private vault;

    uint256 private constant RATE = 2e18; // 1 yield token = 2 underlying
    uint256 private constant MIN_COLLAT = 1_500_000_000_000_000_000; // 1.5x

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND", 18);
        yieldToken = new MockERC20("Yield", "YLD", 18);
        alchemist = new MockAlchemistV3Units(RATE, MIN_COLLAT);
        alchemist.setDepositCap(80 ether);
        alchemist.setTotalDeposited(0);

        LeveragedVault impl = new LeveragedVault();
        vault = LeveragedVault(payable(Clones.clone(address(impl))));
        vault.initialize(
            address(yieldToken),
            address(underlying),
            address(alchemist),
            address(0xBEEF),
            100,
            100,
            address(0xCAFE),
            address(0xF00D),
            address(0x1234),
            address(0x5678),
            address(this)
        );
    }

    function _setVaultPosition() internal {
        uint256 slot = stdstore.target(address(vault)).sig("vaultPositionId()").find();
        vm.store(address(vault), bytes32(slot), bytes32(uint256(1)));
    }

    function testRedeemableBalanceUsesUnderlyingValue() public {
        _setVaultPosition();
        alchemist.setCDP(100 ether, 40 ether); // 100 yield -> 200 underlying
        underlying.mint(address(vault), 50 ether);

        uint256 redeemable = vault.getVaultRedeemableBalance();
        assertEq(redeemable, 210 ether);
    }

    function testFreeWithdrawCapacityUsesUnderlyingValue() public {
        _setVaultPosition();
        alchemist.setCDP(100 ether, 40 ether); // 200 underlying collateral, 40 debt

        uint256 free = vault.getFreeWithdrawCapacity();
        assertEq(free, 140 ether);
    }

    function testTotalWithdrawCapacityUsesUnderlyingValue() public {
        _setVaultPosition();
        alchemist.setCDP(100 ether, 0);

        uint256 total = vault.getTotalWithdrawCapacity();
        assertEq(total, 200 ether);
    }

    function testLeverageParametersClampByYieldCapacity() public {
        (uint256 clampedDeposit, uint256 flashLoanAmount, uint256 underlyingDepositMin,,) =
            vault.getLeverageParameters(200 ether, 0, 0);

        assertEq(clampedDeposit, 160 ether);
        assertEq(flashLoanAmount, 0);
        assertEq(underlyingDepositMin, 80 ether);
    }
}
