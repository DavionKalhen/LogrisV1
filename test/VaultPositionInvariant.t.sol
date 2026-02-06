// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../src/LeveragedVault.sol";

contract MockERC20Token is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPositionNFT {
    address public alchemist;
    uint256 private _currentTokenId;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(address => uint256[]) private _ownedTokens;
    mapping(uint256 => uint256) private _ownedTokensIndex;

    constructor(address alchemist_) {
        alchemist = alchemist_;
    }

    function mint(address to) external returns (uint256) {
        require(msg.sender == alchemist, "Only alchemist");
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _owners[tokenId] = to;
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
        return tokenId;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "Invalid token");
        return owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256) {
        require(index < _ownedTokens[owner].length, "Index out of bounds");
        return _ownedTokens[owner][index];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(msg.sender == from, "Not authorized");
        require(_owners[tokenId] == from, "Not owner");

        _owners[tokenId] = to;

        uint256 fromIndex = _ownedTokensIndex[tokenId];
        uint256 lastIndex = _ownedTokens[from].length - 1;
        if (fromIndex != lastIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastIndex];
            _ownedTokens[from][fromIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = fromIndex;
        }
        _ownedTokens[from].pop();
        _balances[from] -= 1;

        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);
        _balances[to] += 1;
    }
}

contract MockAlchemistV3 {
    address public yieldToken;
    address public debtToken;
    MockPositionNFT public positionNFT;

    uint256 public depositCap = type(uint256).max;
    uint256 public totalDeposited;

    constructor(address _yieldToken, address _debtToken) {
        yieldToken = _yieldToken;
        debtToken = _debtToken;
        positionNFT = new MockPositionNFT(address(this));
    }

    function alchemistPositionNFT() external view returns (address) {
        return address(positionNFT);
    }

    function depositsPaused() external pure returns (bool) {
        return false;
    }

    function loansPaused() external pure returns (bool) {
        return false;
    }

    function getTotalDeposited() external view returns (uint256) {
        return totalDeposited;
    }

    function minimumCollateralization() external pure returns (uint256) {
        return 1e18;
    }

    function getMaxBorrowable(uint256) external pure returns (uint256) {
        return type(uint256).max;
    }

    function getCDP(uint256) external view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        return (totalDeposited, 0, 0);
    }

    function normalizeDebtTokensToUnderlying(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertYieldTokensToUnderlying(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function convertUnderlyingTokensToYield(uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256) {
        if (recipientId == 0) {
            positionNFT.mint(recipient);
        }
        totalDeposited += amount;
        ERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        return 0;
    }

    function mintPosition(address to) external returns (uint256) {
        return positionNFT.mint(to);
    }
}

contract VaultPositionInvariantTest is Test {
    MockERC20Token private underlying;
    MockERC20Token private yieldToken;
    MockERC20Token private debtToken;
    MockAlchemistV3 private alchemist;
    LeveragedVault private vault;

    function setUp() public {
        underlying = new MockERC20Token("Underlying", "UND");
        yieldToken = new MockERC20Token("Yield", "YLD");
        debtToken = new MockERC20Token("Debt", "DBT");
        alchemist = new MockAlchemistV3(address(yieldToken), address(debtToken));

        vault = new LeveragedVault(
            "Leveraged Vault",
            "LVLT",
            address(yieldToken),
            address(underlying),
            address(alchemist),
            address(this), // leverager
            100,  // 1% underlying slippage
            200,  // 2% debt slippage
            address(0xCAFE),
            address(0xF00D),
            address(0xBEEF),
            address(underlying)
        );
    }

    function _mintYield(uint256 amount) internal {
        yieldToken.mint(address(this), amount);
        yieldToken.approve(address(vault), amount);
    }

    function test_RevertIfPositionAlreadyExists() public {
        _mintYield(10 ether);

        alchemist.mintPosition(address(vault));

        vm.expectRevert("Position already exists");
        vault.vaultDepositYieldTokens(10 ether);
    }

    function test_SweepUnknownPosition() public {
        _mintYield(10 ether);
        vault.vaultDepositYieldTokens(10 ether);

        uint256 activeId = vault.getVaultPositionId();
        uint256 extraId = alchemist.mintPosition(address(vault));
        MockPositionNFT nft = MockPositionNFT(alchemist.alchemistPositionNFT());

        assertEq(nft.balanceOf(address(vault)), 2);

        vm.expectRevert("Cannot sweep active position");
        vault.sweepUnknownPosition(activeId, address(0xBEEF));

        vault.sweepUnknownPosition(extraId, address(0xBEEF));
        assertEq(nft.ownerOf(extraId), address(0xBEEF));
        assertEq(nft.balanceOf(address(vault)), 1);
    }
}
