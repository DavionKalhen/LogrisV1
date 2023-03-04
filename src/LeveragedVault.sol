// SPDX-License-Identifier: MIT
import "./ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/uniswap/TransferHelper.sol";
import "./interfaces/ILeveragedVault.sol";
import "./interfaces/ILeverager.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is ERC4626, Ownable, ILeveragedVault {
    ILeverager private leverager;
    IERC20 private yieldToken;
    IERC20 private underlyingToken;
    uint32 public underlyingSlippageBasisPoints;
    uint32 public debtSlippageBasisPoints;

    constructor(string memory _tokenName, string memory _tokenDescription, address _yieldToken, address _underlyingToken, address _leverager, uint32 _underlyingSlippageBasisPoints, uint32 _debtSlippageBasisPoints)
    ERC4626(IERC20(_yieldToken))
    ERC20(_tokenDescription, _tokenName) {
        leverager = ILeverager(_leverager);
        yieldToken = IERC20(_yieldToken);
        underlyingToken = IERC20(_underlyingToken);
        underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        debtSlippageBasisPoints = _debtSlippageBasisPoints;
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

    function depositUnderlying(uint amount) public returns(uint shares) {
        require(amount <= maxDeposit(msg.sender), "ERC4626: deposit more than max");

        shares = previewDeposit(amount);    
        _deposit(msg.sender, msg.sender, amount, shares);
        emit DepositUnderlying(msg.sender, address(underlyingToken), amount);
    }

    function withdrawUnderlying(uint256 shares) public virtual override returns (uint256 amount) {
        require(shares <= balanceOf(msg.sender), "You don't have enough deposited");
        uint underlyingWithdrawAmount = convertSharesToUnderlyingTokens(shares);
        uint depositPoolBalance = underlyingToken.balanceOf(address(this));
        if(depositPoolBalance < underlyingWithdrawAmount) {
            leverager.withdrawUnderlying(underlyingWithdrawAmount-depositPoolBalance);
        }
        _withdraw(msg.sender, msg.sender, msg.sender, shares, underlyingWithdrawAmount);
        emit WithdrawUnderlying(msg.sender, address(underlyingToken), amount);
        return underlyingWithdrawAmount;
    }

    function leverage() external {
        uint256 depositAmount = underlyingToken.balanceOf(address(this));
        int256 debtBefore = leverager.getDebtBalance(address(this));
        address(leverager).delegatecall(
            abi.encodeWithSignature("getApproval(uint)", leverager.getDebtBalance(address(this)))
        );
        leverager.leverage(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
        emit Leverage(address(underlyingToken), depositAmount, leverager.getDebtBalance(address(this)) - debtBefore);
    }

    function totalAssets() public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return underlyingToken.balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }
}