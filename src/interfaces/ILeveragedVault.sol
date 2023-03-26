import "./IERC4626.sol";

pragma solidity ^0.8.0;

interface ILeveragedVault is IERC4626 {
    event DepositUnderlying(address indexed sender, address indexed underlyingToken, uint256 amount);
    event WithdrawUnderlying(address indexed sender, address indexed underlyingToken, uint256 shares);
    event Leverage(address indexed yieldToken, uint256 depositAmount, int256 debtAmount);
    
    /* we'll support depositYield as a stretch goal
    either add a token address parameter to the getBalance calls or add new view functions for getYield
    function getVaultAssets() external view returns(address[] memory);
    event DepositYield(address indexed sender, address indexed yieldToken, uint256 amount);
    function depositYield(uint amount) external returns(uint shares);
    */
    function getYieldToken() external view returns(address yieldToken);
    function getUnderlyingToken() external view returns(address underlyingToken);
    function getDepositPoolBalance() external view returns(uint amount);
    function getVaultDepositedBalance() external view returns(uint amount);
    function getVaultDebtBalance() external view returns(int256 amount);
    function getVaultRedeemableBalance() external view returns(uint amount);
    function convertUnderlyingTokensToShares(uint256 amount) external view returns (uint256 shares);
    function convertSharesToUnderlyingTokens(uint256 shares) external view returns (uint256 amount);
    function getLeverageParameters() external view returns(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin);
    function getWithdrawUnderlyingParameters(uint shares) external view returns(uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut);

    function depositUnderlying(uint amount) external returns(uint shares);
    function depositUnderlying() external payable returns(uint shares);
    function leverage(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) external;
    function withdrawUnderlying(uint shares, uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) external returns(uint amount);
}