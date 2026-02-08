// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/adapters/CurveSwapper.sol";

contract MockERC20Swap {
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

contract MockWETHSwap is MockERC20Swap("Wrapped ETH", "WETH") {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract MockCurvePoolSwap {
    address public debtToken;
    address public underlyingToken;
    int128 public ethIndex;
    int128 public alEthIndex;
    bool public usesEth;

    constructor(
        address _debtToken,
        address _underlyingToken,
        int128 _ethIndex,
        int128 _alEthIndex,
        bool _usesEth
    ) {
        debtToken = _debtToken;
        underlyingToken = _underlyingToken;
        ethIndex = _ethIndex;
        alEthIndex = _alEthIndex;
        usesEth = _usesEth;
    }

    function get_dy(int128, int128, uint256 dx) external pure returns (uint256) {
        return dx;
    }

    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        return dx;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256) {
        return _exchange(i, j, dx, min_dy);
    }

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256) {
        return _exchange(int128(int256(i)), int128(int256(j)), dx, min_dy);
    }

    function fee() external pure returns (uint256) {
        return 0;
    }

    function _exchange(int128, int128 j, uint256 dx, uint256 min_dy) internal returns (uint256) {
        require(dx >= min_dy, "min");
        uint256 out = dx;
        if (usesEth && j == ethIndex) {
            require(address(this).balance >= out, "insufficient eth");
            payable(msg.sender).transfer(out);
        } else {
            address outToken = j == alEthIndex ? debtToken : underlyingToken;
            MockERC20Swap(outToken).mint(msg.sender, out);
        }
        return out;
    }

    receive() external payable {}
}

contract CurveSwapperUnitTest is Test {
    address private user = address(0xBEEF);

    function testSwapNonEthDebtToUnderlying() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockERC20Swap underlying = new MockERC20Swap("Underlying", "UND");
        MockWETHSwap weth = new MockWETHSwap();
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(underlying), 0, 1, false);

        CurveSwapper swapper = new CurveSwapper(
            address(pool),
            address(debt),
            address(underlying),
            0,
            1,
            address(weth),
            false,
            address(this)
        );

        debt.mint(user, 10 ether);
        vm.startPrank(user);
        debt.approve(address(swapper), 10 ether);
        uint256 out = swapper.swapDebtToUnderlying(10 ether, 1, user, "");
        vm.stopPrank();

        assertEq(out, 10 ether);
        assertEq(underlying.balanceOf(user), 10 ether);
    }

    function testSwapNonEthUnderlyingToDebt() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockERC20Swap underlying = new MockERC20Swap("Underlying", "UND");
        MockWETHSwap weth = new MockWETHSwap();
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(underlying), 0, 1, false);

        CurveSwapper swapper = new CurveSwapper(
            address(pool),
            address(debt),
            address(underlying),
            0,
            1,
            address(weth),
            false,
            address(this)
        );

        underlying.mint(user, 5 ether);
        vm.startPrank(user);
        underlying.approve(address(swapper), 5 ether);
        uint256 out = swapper.swapUnderlyingToDebt(5 ether, 1, user, "");
        vm.stopPrank();

        assertEq(out, 5 ether);
        assertEq(debt.balanceOf(user), 5 ether);
    }

    function testSwapEthDebtToUnderlying() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockWETHSwap weth = new MockWETHSwap();
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(weth), 0, 1, true);

        vm.deal(address(pool), 10 ether);

        CurveSwapper swapper = new CurveSwapper(
            address(pool),
            address(debt),
            address(weth),
            0,
            1,
            address(weth),
            true,
            address(this)
        );

        debt.mint(user, 3 ether);
        vm.startPrank(user);
        debt.approve(address(swapper), 3 ether);
        uint256 out = swapper.swapDebtToUnderlying(3 ether, 1, user, "");
        vm.stopPrank();

        assertEq(out, 3 ether);
        assertEq(weth.balanceOf(user), 3 ether);
    }

    function testSwapEthUnderlyingToDebt() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockWETHSwap weth = new MockWETHSwap();
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(weth), 0, 1, true);

        CurveSwapper swapper = new CurveSwapper(
            address(pool),
            address(debt),
            address(weth),
            0,
            1,
            address(weth),
            true,
            address(this)
        );

        vm.deal(user, 4 ether);
        vm.startPrank(user);
        weth.deposit{value: 4 ether}();
        weth.approve(address(swapper), 4 ether);
        uint256 out = swapper.swapUnderlyingToDebt(4 ether, 1, user, "");
        vm.stopPrank();

        assertEq(out, 4 ether);
        assertEq(debt.balanceOf(user), 4 ether);
    }

    function testConstructorRejectsZeroWeth() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockERC20Swap underlying = new MockERC20Swap("Underlying", "UND");
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(underlying), 0, 1, false);

        vm.expectRevert(CurveSwapper.ZeroAddress.selector);
        new CurveSwapper(
            address(pool),
            address(debt),
            address(underlying),
            0,
            1,
            address(0),
            false,
            address(this)
        );
    }

    function testConstructorRequiresWethWhenUsingEth() public {
        MockERC20Swap debt = new MockERC20Swap("Debt", "DBT");
        MockERC20Swap underlying = new MockERC20Swap("Underlying", "UND");
        MockWETHSwap weth = new MockWETHSwap();
        MockCurvePoolSwap pool = new MockCurvePoolSwap(address(debt), address(underlying), 0, 1, true);

        vm.expectRevert(CurveSwapper.UnderlyingMustBeWETH.selector);
        new CurveSwapper(
            address(pool),
            address(debt),
            address(underlying),
            0,
            1,
            address(weth),
            true,
            address(this)
        );
    }
}
