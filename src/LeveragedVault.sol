// SPDX-License-Identifier: MIT
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/ILeveragedVault.sol";
import "./interfaces/ILeverager.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is ERC4626, Ownable, ILeveragedVault {
    ILeverager private leverager;
    IERC20 private yieldToken;
    IERC20 private underlyingToken;
    uint32 public allowedSlippageBasisPoints;

    constructor(string memory _tokenName, string memory _tokenDescription, address _yieldToken, address _underlyingToken, address _leverager, uint32 _allowedSlippageBasisPoints)
    ERC4626(IERC20(_yieldToken))
    ERC20(_tokenDescription, _tokenName) {
        leverager = ILeverager(_leverager);
        yieldToken = IERC20(_yieldToken);
        underlyingToken = IERC20(_underlyingToken);
        allowedSlippageBasisPoints = _allowedSlippageBasisPoints;
    }

    function getYieldToken() external view returns(address){
        return address(yieldToken);
    }

    function getUnderlyingToken() external view returns(address){
        return address(underlyingToken);
    }

    function getDepositPoolBalance() external view returns(uint amount) {
        return underlyingToken.balanceOf(address(this));
    }

    function getVaultDepositedBalance() external view returns(uint amount){
        return leverager.getDepositedBalance(address(this));
    }

    function getVaultDebtBalance() external view returns(int256) {
        return leverager.getDebtBalance(address(this));
    }

    function getVaultRedeemableBalance() public view returns(uint) {
        return underlyingToken.balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }

    function convertUnderlyingTokensToShares(uint256 amount) public view returns (uint256 shares) {
        return amount * totalSupply() / getVaultRedeemableBalance();
    }

    function convertSharesToUnderlyingTokens(uint256 shares) public view returns (uint256) {
        return shares * getVaultRedeemableBalance() / totalSupply();
    }

    function depositUnderlying(uint amount, address recipient) public returns(uint) {
        uint shares = super.deposit(amount, recipient);
        emit Deposit(recipient, address(underlyingToken), amount);
        return shares;
    }

    function withdrawUnderlying(uint shares, address to) external returns(uint amount) {
        require(shares <= balanceOf(msg.sender), "You don't have enough deposited");
        uint underlyingWithdrawAmount = convertSharesToUnderlyingTokens(shares);
        uint depositPoolBalance = underlyingToken.balanceOf(address(this));
        if(depositPoolBalance < underlyingWithdrawAmount) {
            leverager.withdrawUnderlying(underlyingWithdrawAmount-depositPoolBalance);
        }
        amount = super.withdraw(shares, to, address(this));
        emit Withdraw(msg.sender, address(underlyingToken), shares);
        return amount;
    }

    function leverage() external {
        uint256 minAmountOut = (yieldToken.balanceOf(address(this)) * (10000 - allowedSlippageBasisPoints)) / 10000;
        uint256 amountOut = yieldToken.balanceOf(address(this));
        leverager.leverage(minAmountOut, amountOut);
        emit Leverage(address(yieldToken), amountOut, amountOut);
    }
}