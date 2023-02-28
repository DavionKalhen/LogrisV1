pragma solidity 0.8.19;

import "./euler/IFlashLoan.sol";

interface ILeverager is IFlashLoan {
    function getYieldToken() external view returns(address yieldToken);
    function getUnderlyingToken() external view returns(address underlyingToken);
    function getDebtToken() external view returns(address debtToken);
    function getFlashLoan() external view returns (address flashLoan);
    function getDebtSource() external view returns (address debtSource);
    function getDexPool() external view returns (address dexPool);

    function getDepositedBalance(address depositor) external view returns(uint amount);
    function getDebtBalance(address depositor) external view returns(int256 amount);
    function getRedeemableBalance(address depositor) external view returns(uint amount);

    function withdraw(uint shares) external returns(uint amount);
    function leverage(uint slippageTolerance, uint depositAmount) external;
}