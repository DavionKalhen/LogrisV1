pragma solidity 0.8.13;
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./MockRETH.sol";
import "./MockalETH.sol";

contract AlchemistV2 {
    uint256 totalShares;
    RETH rETH;
    ALETH alETH;

    constructor() {
        rETH = new RETH();
        rETH.mint(msg.sender, 20000 ether);
    }

    function deposit(
        address yieldToken,
        uint256 amount,
        address recipient
    ) external returns (uint256) {
        // Deposit the yield tokens to the recipient.
        // Transfer tokens from the message sender now that the internal storage updates have been committed.
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);

        return amount;
    }

    function withdraw(
        address yieldToken,
        uint256 shares,
        address recipient
    ) external returns (uint256) {

        // Withdraw the shares from the system.
        uint256 amountYieldTokens = shares;
        // Transfer the yield tokens to the recipient.
        IERC20(yieldToken).transfer(recipient, amountYieldTokens);

        return amountYieldTokens;
    }
    function mint(uint256 amount, address recipient) external {
        if(alETH.totalSupply() == rETH.balanceOf(address(this))/2) {
            revert("alETH is already minted to the max");
        }
        if(amount + alETH.totalSupply() > rETH.balanceOf(address(this))/2) {
            alETH.mint(recipient, rETH.balanceOf(address(this))/2 - alETH.totalSupply());
        } else {
            alETH.mint(recipient, amount);
        }
    }
}