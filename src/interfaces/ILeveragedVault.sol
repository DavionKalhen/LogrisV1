import "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

pragma solidity ^0.8.0;

interface ILeveragedVault is IERC4626 {
    event Deposit(address indexed sender, address indexed yieldToken, uint256 amount);
    event Withdraw(address indexed sender, address indexed yieldToken, uint256 shares);
    event Leverage(address indexed yieldToken, uint256 depositAmount, uint256 debtAmount);

    error SlippageExceeded();

    /* we'll support depositUnderlying as a stretch goal
    either add a token address parameter to the getBalance calls or add new view functions for getUnderlying
    function getVaultAssets() external view returns(address[] memory);
    event DepositUnderlying(address indexed sender, address indexed underlyingToken, uint256 amount);
    function depositUnderlying(uint amount) external returns(uint shares);
    */
    function getYieldToken() external view returns(address yieldToken);
    function getUnderlyingToken() external view returns(address underlyingToken);
    function getDepositPoolBalance() external view returns(uint amount);
    function getVaultDepositedBalance() external view returns(uint amount);
    function getVaultDebtBalance() external view returns(uint amount);
    function getVaultRedeemableBalance() external view returns(uint amount);
    function convertYieldTokensToShares(uint256 amount) external view returns (uint256 shares);
    function convertSharesToYieldTokens(uint256 shares) external view returns (uint256 amount);
    function deposit(uint amount, address to) external returns(uint shares);
    function withdraw(uint shares, address to) external returns(uint amount);
    function leverage() external;
}