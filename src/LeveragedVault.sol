// SPDX-License-Identifier: MIT
import "./ERC4626.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/uniswap/TransferHelper.sol";
import "./interfaces/alchemist/IAlchemistV2.sol";
import "./interfaces/ILeveragedVault.sol";
import "./interfaces/ILeverager.sol";
import "./interfaces/wETH/IWETH.sol";

import "forge-std/console.sol";

pragma solidity ^0.8.19;

contract LeveragedVault is Ownable, ERC4626, ILeveragedVault {
    ILeverager private leverager;
    IERC20 private yieldToken;
    IERC20 private underlyingToken;
    uint32 public underlyingSlippageBasisPoints;
    uint32 public debtSlippageBasisPoints;
    IWETH private wETH;
    address public debtSource;
    address constant wETHAddress  = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    constructor(
        string memory _tokenName,
        string memory _tokenDescription,
        address _yieldToken,
        address _underlyingToken,
        address _leverager,
        address _debtSource,
        uint32 _underlyingSlippageBasisPoints,
        uint32 _debtSlippageBasisPoints) payable
        ERC4626(IERC20(_yieldToken))
        ERC20(_tokenDescription, _tokenName)
    {
        leverager = ILeverager(_leverager);
        yieldToken = IERC20(_yieldToken);
        underlyingToken = IERC20(_underlyingToken);
        underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        debtSlippageBasisPoints = _debtSlippageBasisPoints;
        wETH = IWETH(wETHAddress);

        debtSource = _debtSource;
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
        console.log(totalSupply());
        return shares * getVaultRedeemableBalance() / totalSupply();
    }

    function depositUnderlying(uint amount) external returns(uint shares) {
        require(amount <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
        
        shares = previewDeposit(amount);    
        _deposit(msg.sender, msg.sender, amount, shares);
        emit DepositUnderlying(msg.sender, address(underlyingToken), amount);
    }

    function depositUnderlying() external payable returns(uint shares){
        require(msg.value <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
        require(address(underlyingToken) == address(wETH), "ERC4626: depositing ETH to non-wETH vault");
        wETH.deposit{value:msg.value}();
        shares = previewDeposit(msg.value);
        _depositETH(msg.sender, msg.sender, msg.value, shares);
        emit DepositUnderlying(msg.sender, address(underlyingToken), msg.value);
    }

    function withdrawUnderlying(uint256 shares) external virtual override returns (uint256 amount) {
        require(shares <= balanceOf(msg.sender), "You don't have enough deposited");
        uint underlyingWithdrawAmount = convertSharesToUnderlyingTokens(shares);
        uint depositPoolBalance = underlyingToken.balanceOf(address(this));
        if(depositPoolBalance < underlyingWithdrawAmount) {
            leverager.withdrawUnderlying(underlyingWithdrawAmount-depositPoolBalance, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
        }
        _withdraw(msg.sender, msg.sender, msg.sender, shares, underlyingWithdrawAmount);
        emit WithdrawUnderlying(msg.sender, address(underlyingToken), amount);
        return underlyingWithdrawAmount;
    }

    function leverage() external {
        uint256 depositAmount = underlyingToken.balanceOf(address(this));
        int256 debtBefore = leverager.getDebtBalance(address(this));
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //this calculation won't be right until the getLeverageParameters call has been written
        alchemist.approveMint(address(leverager), depositAmount);      

        wETH.approve(address(leverager), depositAmount);
        leverager.leverage(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
        emit Leverage(address(underlyingToken), depositAmount, leverager.getDebtBalance(address(this)) - debtBefore);
    }

    function totalAssets() public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return underlyingToken.balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }
}