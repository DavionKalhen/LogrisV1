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

pragma solidity 0.8.19;

/**

*/
contract LeveragedVault is Ownable, ERC4626, ILeveragedVault {

    ILeverager public leverager;
    IERC20 private _underlyingToken;
    uint32 public underlyingSlippageBasisPoints;
    uint32 public debtSlippageBasisPoints;
    IWETH public wETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public debtSource;

    constructor(
    string memory tokenName,
    string memory tokenDescription,
    address yieldToken,
    address underlyingTokenAddress,
    address _leverager,
    address _debtSource,
    uint32 _underlyingSlippageBasisPoints,
    uint32 _debtSlippageBasisPoints) payable
    ERC4626(IERC20(yieldToken))
    ERC20(tokenDescription, tokenName)
    Ownable()
    {
        leverager = ILeverager(_leverager);
        _underlyingToken = IERC20(underlyingTokenAddress);
        underlyingSlippageBasisPoints = _underlyingSlippageBasisPoints;
        debtSlippageBasisPoints = _debtSlippageBasisPoints;
        debtSource = _debtSource;
    }

    function getYieldToken() external view override(ILeveragedVault) returns(address yieldToken) {
        return asset();
    }

    function getUnderlyingToken() external override(ILeveragedVault) view returns(address underlyingToken) {
        return address(_underlyingToken);
    }

    function getDepositPoolBalance() external view returns(uint amount) {
        return _underlyingToken.balanceOf(address(this));
    }

    function getVaultDepositedBalance() external view returns(uint amount){
        return leverager.getDepositedBalance(address(this));
    }

    function getVaultDebtBalance() external view returns(int256) {
        return leverager.getDebtBalance(address(this));
    }

    function getVaultRedeemableBalance() public view returns(uint) {
        return _underlyingToken.balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }

    function getLeverageParameters() external view returns(uint clampedDeposit,
                                                           uint flashLoanAmount,
                                                           uint underlyingDepositMin,
                                                           uint mintAmount,
                                                           uint debtTradeMin) {
        (clampedDeposit,
        flashLoanAmount,
        underlyingDepositMin,
        mintAmount,
        debtTradeMin) = leverager.getLeverageParameters(
            _underlyingToken.balanceOf(address(this)),
            underlyingSlippageBasisPoints,
            debtSlippageBasisPoints);
    }

    function getWithdrawUnderlyingParameters(uint leveragerShares) external view returns(uint flashLoanAmount,
                                                                                         uint burnAmount,
                                                                                         uint debtTradeMin,
                                                                                         uint minUnderlyingOut) {
        (flashLoanAmount,
        burnAmount,
        debtTradeMin,
        minUnderlyingOut) = leverager.getWithdrawUnderlyingParameters(
            leveragerShares,
            underlyingSlippageBasisPoints,
            debtSlippageBasisPoints);
    }

    function convertUnderlyingTokensToShares(uint256 amount) public view returns (uint256 leveragedVaultShares) {
        return amount * totalSupply() / getVaultRedeemableBalance();
    }

    function convertSharesToUnderlyingTokens(uint256 leveragedVaultShares) public view returns (uint256) {
        console.log(totalSupply());
        return leveragedVaultShares * getVaultRedeemableBalance() / totalSupply();
    }

    function depositUnderlying(uint amount) external returns(uint leveragedVaultShares) {
        require(amount <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
        
        leveragedVaultShares = previewDeposit(amount);    
        _deposit(msg.sender, msg.sender, amount, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address(_underlyingToken), amount);
    }

    function depositUnderlying() external payable returns(uint leveragedVaultShares){
        require(msg.value <= maxDeposit(msg.sender), "ERC4626: deposit more than max");
        require(address(_underlyingToken) == address(wETH), "ERC4626: depositing ETH to non-wETH vault");
        wETH.deposit{value:msg.value}();
        leveragedVaultShares = previewDeposit(msg.value);
        _depositETH(msg.sender, msg.sender, msg.value, leveragedVaultShares);
        emit DepositUnderlying(msg.sender, address(_underlyingToken), msg.value);
    }

    function leverage(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin) external {
        uint256 depositAmount = _underlyingToken.balanceOf(address(this));
        int256 debtBefore = leverager.getDebtBalance(address(this));
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //this calculation won't be right until the getLeverageParameters call has been written
        alchemist.approveMint(address(leverager), depositAmount);      

        wETH.approve(address(leverager), depositAmount);
        leverager.leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
        //TODO: sanity check the amount actually deposited to protect against a malicious leverager contract here
        emit Leverage(address(_underlyingToken), depositAmount, leverager.getDebtBalance(address(this)) - debtBefore);
    }

    function withdrawUnderlying(uint leveragedVaultShares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut) external virtual returns (uint256 underlyingWithdrawAmount) {
        require(leveragedVaultShares <= balanceOf(msg.sender), "You don't have enough deposited");
        // I'm skeptical you'll ever have underlyingWithdrawAmount after accounting for slippage
        underlyingWithdrawAmount = convertSharesToUnderlyingTokens(leveragedVaultShares);
        uint depositPoolBalance = _underlyingToken.balanceOf(address(this));
        if(depositPoolBalance < underlyingWithdrawAmount) {
            uint leveragerShares = leverager.convertUnderlyingTokensToShares(
                underlyingWithdrawAmount-depositPoolBalance);
            leverager.withdrawUnderlying(leveragerShares, flashLoanAmount, burnAmount, debtTradeMin, minUnderlyingOut);
        }
        //TODO: sanity check the amount actually withdrawn to protect against a malicious leverager contract here
        _withdraw(msg.sender, msg.sender, msg.sender, leveragedVaultShares, underlyingWithdrawAmount);
        emit WithdrawUnderlying(msg.sender, address(_underlyingToken), underlyingWithdrawAmount);
    }

    function totalAssets() public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return _underlyingToken.balanceOf(address(this)) + leverager.getRedeemableBalance(address(this));
    }
}