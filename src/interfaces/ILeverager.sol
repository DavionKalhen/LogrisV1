pragma solidity 0.8.19;

import "./euler/IFlashLoan.sol";

interface ILeverager is IFlashLoan {
    function getDepositedBalance(address depositor) external view returns(uint amount);
    function getDebtBalance(address depositor) external view returns(int256 amount);
    function getRedeemableBalance(address depositor) external view returns(uint amount);

    function withdrawUnderlying(uint amount) external;
    function leverage(uint depositAmount, uint minDepositAmount) external;
}