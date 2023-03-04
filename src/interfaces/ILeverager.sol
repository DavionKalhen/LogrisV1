pragma solidity 0.8.19;

import "./euler/IFlashLoan.sol";

interface ILeverager is IFlashLoan {
    event DepositUnderlying(address indexed underlyingToken, uint256 sent, uint256 credited);
    event Mint(address indexed yieldToken, uint256 amount);
    event Swap(address debtToken, address underlyingToken, uint256 debtAmount, uint256 underlyingAmount);

    function getDepositedBalance(address depositor) external view returns(uint amount);
    function getDebtBalance(address depositor) external view returns(int256 amount);
    function getRedeemableBalance(address depositor) external view returns(uint amount);
    function getBorrowCapacity(address depositor) external view returns(uint amount);
    function getWithdrawCapacity(address _depositor) external view returns(uint amount);

    function withdrawUnderlying(uint amount, uint32 underlyingSlippageBasisPoints) external returns(uint withdrawnAmount);
    function leverage(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external;
}