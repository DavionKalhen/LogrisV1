
interface ILogrisV1Vault {
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Leverage(address indexed user, address indexed token, uint256 amount);

    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function leverage(address token, uint256 amount) external;
}