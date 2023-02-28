// SPDX-License-Identifier: MIT
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/ILeveragedVault.sol";
import "src/Leverager.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is ERC4626, Ownable, ILeveragedVault {
    Leverager public leverager;
    mapping(address => uint256) public deposited;
    address private _underlyingAsset;
    address private _yieldToken;
    uint256 public allowedSlippage = 10; //0.1%;

    constructor(address _token, address _wrapper)
    ERC4626(IERC20(_token))
    //these strings should be provided by the factory if you want this contract to be reusable
    ERC20("Alchemix Leveraged Vault WETH", "lvyvETH") {
        leverager = new Leverager(_wrapper);
    }

    function getYieldToken() external pure returns(address){
        return _yieldToken;
    }

    function getUnderlyingAsset() external pure returns(address){
        return _underlyingAsset;
    }

    function getDepositPoolBalance() external view returns(uint amount) {
        return IERC20(_yieldToken).balanceOf(address(this));
    }

    function getVaultDepositedBalance() external view returns(uint amount){
        return leverager.getDepositedBalance(address(this));
    }
    function getVaultDebtBalance() external view returns(uint) {
        return leverager.getDebtBalance(address(this));
    }
    function getVaultRedeemableBalance() external view returns(uint) {
        return leverager.getRedeemableBalance(address(this));
    }

    function convertYieldTokensToShares(uint256 amount) external view returns (uint256 shares) {
        return amount * totalSupply() / _calculateUnrealizedBalance(_yieldToken);
    }

    function _calculateUnrealizedBalance(address yieldToken) internal view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }

    function convertSharesToYieldTokens(uint256 shares) external view returns (uint256) {
        return shares * _calculateUnrealizedBalance(_yieldToken) / totalSupply();
    }

    function deposit(uint amount, address to) public override(ERC4626, ILeveragedVault) virtual returns(uint) {
        uint shares = super.deposit(amount, to);
        deposited[to] += amount;
        emit Deposit(to, _yieldToken, amount);
        return shares;
        
    }
    function withdraw(uint shares, address to) external returns(uint amount) {
        require(shares <= deposited[msg.sender], "You don't have enough deposited");
        uint share_balance = IERC20(_yieldToken).balanceOf(address(this));
        if(share_balance < shares) {
            leverager.withdraw(shares-share_balance);
        }
        amount = super.withdraw(shares, to, address(this));
        deposited[msg.sender] -= amount;
        emit Withdraw(msg.sender, _yieldToken, shares);
        return amount;
    }

    function leverage() external {
        uint256 minAmountOut = (IERC20(_yieldToken).balanceOf(address(this)) * (10000 - allowedSlippage)) / 10000;
        uint256 amountOut = IERC20(_yieldToken).balanceOf(address(this));
        leverager.leverage(minAmountOut, amountOut);
        emit Leverage(_yieldToken, amountOut, amountOut);
    }
}