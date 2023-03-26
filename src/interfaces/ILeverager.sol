pragma solidity 0.8.19;

import "./euler/IFlashLoan.sol";

interface ILeverager is IFlashLoan {
    event DepositUnderlying(address indexed underlyingToken, uint256 sent, uint256 credited);
    event Mint(address indexed yieldToken, uint256 amount);
    event Swap(address debtToken, address underlyingToken, uint256 debtAmount, uint256 underlyingAmount);
    event Burn(address debtToken, uint amount);
    event WithdrawUnderlying(address indexed underlyingToken, uint256 shares, uint256 underlying);

    function getDepositedBalance(address depositor) external view returns(uint amount);
    function getDebtBalance(address depositor) external view returns(int256 amount);
    function getRedeemableBalance(address depositor) external view returns(uint amount);
    function getBorrowCapacity(address depositor) external view returns(uint amount);
    function getFreeWithdrawCapacity(address _depositor) external view returns(uint shares);
    function getTotalWithdrawCapacity(address _depositor) external view returns(uint shares);
    function convertUnderlyingTokensToShares(uint amount) external view returns (uint shares);
    function getLeverageParameters(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external view returns(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin);
    function getWithdrawUnderlyingParameters(uint shares, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external view returns(uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut);

    function leverage(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) external;
    function leverageAtomic(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external;
    function withdrawUnderlying(uint shares, uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) external;
    function withdrawUnderlyingAtomic(uint shares, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external;
}