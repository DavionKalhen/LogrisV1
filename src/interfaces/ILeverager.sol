pragma solidity 0.8.19;

import "./euler/IFlashLoan.sol";

interface ILeverager is IFlashLoan {
    function getDepositedBalance(address depositor) external view returns(uint amount);
    function getDebtBalance(address depositor) external view returns(uint amount);
    function getRedeemableBalance(address depositor) external view returns(uint amount);

    function getYieldToken() external view returns(address yieldToken);
    function getFlashLoanAddress() external view returns (address);
    function getDexAddress() external view returns (address);
    function getDebtSourceAddress() external view returns (address);

    function predictWithdraw(uint shares) external view returns(uint amount);
    function withdraw(uint shares) external returns(uint amount);
    function leverage(uint slippageTolerance, uint depositAmount) external;
}