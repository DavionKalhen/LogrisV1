// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/LeveragedVault.sol";

contract MockERC20Pause {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

contract LeveragedVaultPauseTest is Test {
    MockERC20Pause private underlying;
    MockERC20Pause private yieldToken;
    LeveragedVault private vault;
    address private user = address(0xBEEF);

    function setUp() public {
        underlying = new MockERC20Pause("Underlying", "UND", 18);
        yieldToken = new MockERC20Pause("Yield", "YLD", 18);

        vault = new LeveragedVault(
            "Leveraged Vault",
            "LVLT",
            address(yieldToken),
            address(underlying),
            address(0x1234),
            address(0xBEEF),
            100,
            200,
            address(0xCAFE),
            address(0xF00D),
            address(0x1234),
            address(0x5678)
        );
    }

    function testPauseBlocksDeposit() public {
        vault.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.depositUnderlying(1 ether);
    }

    function testPauseBlocksLeverage() public {
        vault.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.leverage(1, 0, 0, 0, 0);
    }

    function testPauseBlocksWithdrawUnderlying() public {
        vault.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.withdrawUnderlying(1, 0, 0, 0);
    }

    function testPauseBlocksWithdrawUnderlyingAtomic() public {
        vault.pause();
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.withdrawUnderlyingAtomic(1, 0, 0);
    }

    function testUnpauseAllowsDeposit() public {
        vault.pause();
        vault.unpause();

        underlying.mint(user, 1 ether);
        vm.startPrank(user);
        underlying.approve(address(vault), 1 ether);
        vault.depositUnderlying(1 ether);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 1 ether);
    }

    function testOnlyOwnerCanPause() public {
        vm.prank(user);
        vm.expectRevert();
        vault.pause();
    }
}
