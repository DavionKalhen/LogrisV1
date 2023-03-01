// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "./interfaces/alchemist/IAlchemistV2.sol";
import "./interfaces/alchemist/Sets.sol";
import "./interfaces/alchemist/ITokenAdapter.sol";
import "./interfaces/uniswap/TransferHelper.sol";
import "./interfaces/curve/ICurveSwap.sol";
import "./interfaces/euler/DToken.sol";
import "./interfaces/euler/Markets.sol";
import "forge-std/console.sol";


contract Leverager is Ownable {
    IAlchemistV2 public alchemist;
    ICurveSwap curveSwap = ICurveSwap(0x99a58482BD75cbab83b27EC03CA68fF489b5788f);
    DToken dToken;
    Markets markets;

    address yieldToken;
    address debtToken;
    address underlyingToken;
    address wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address eulerMarketsAddress = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;

    uint256 slippage = 100; //1%
    uint256 maxExchangeLoss = 1000; //10%
    constructor(address yieldToken_) {
        alchemist = IAlchemistV2(0x5C6374a2ac4EBC38DeA0Fc1F8716e5Ea1AdD94dd);
        yieldToken = yieldToken_;
    }

     /*
        We need to detect the state we are under relative to the available deposit ceiling.
        In order:
        1) The Alchemix vault is full.
        2) The vault does not have enough deposit capacity even for our deposit pool
            a) We just fill up the pool. No flashloan or mint.
        3) The vault can hold all the deposit pool but not full leverage
            a) We calculate the maximum capacity
            b) We secure flash loan of reduced size
            c) mint/trade repay flash loan
        4) The vault has capacity for maximum leverage. Flow as normal.
    */


    function leverage(uint minDepositAmount, uint depositAmount) external {
        uint depositCapacity = getDepositCapacity();
        require(depositCapacity > 0, "Vault is full");
        require(depositAmount > 0, "Deposit amount must be greater than 0");

        TransferHelper.safeTransferFrom(yieldToken, msg.sender, address(this), depositAmount);
         
        if(depositAmount > depositCapacity) {
            // Vault can't hold all the deposit pool. Fill up the pool.
            depositAmount = depositCapacity;
        }
        else {
            //Calculate flashloan amount. Amount flashed is less a % from total to account for slippage.
            uint flashLoanAmount = (depositAmount - (depositAmount/slippage)) + depositAmount < depositCapacity 
                ? (depositAmount - (depositAmount/100))
                : depositCapacity - depositAmount;
            dToken.flashLoan(flashLoanAmount, abi.encodePacked(flashLoanAmount, depositAmount, minDepositAmount));
            return;
        }
        depositUnderlying(depositAmount, minDepositAmount);
        mintDebtTokens(depositAmount);
        swapDebtTokens(depositAmount);
        return;
    }

    function onFlashLoan(bytes memory data) external {
        (uint flashLoanAmount, uint depositAmount, uint minDepositAmount) = abi.decode(data, (uint, uint, uint));
        depositUnderlying(flashLoanAmount + depositAmount, minDepositAmount + (flashLoanAmount - (flashLoanAmount/slippage)));
        mintDebtTokens(flashLoanAmount + depositAmount);
        swapDebtTokens(flashLoanAmount + depositAmount);
        repayFlashLoan(flashLoanAmount);
        return;
    }

    function depositUnderlying(uint amount, uint minAmountOut) internal {
        IERC20(yieldToken).approve(address(alchemist), amount);
        alchemist.depositUnderlying(yieldToken, amount, address(this), minAmountOut);
    }

    function swapDebtTokens(uint amount) internal {
        (address pool, uint256 amountOut) = curveSwap.getBestRate(debtToken, underlyingToken, amount);
        require(acceptableLoss(amount, amountOut), "Swap exceeds max acceptable loss");
        uint256 amountRecieved = curveSwap.exchange_with_best_rate(debtToken, underlyingToken, amount, amountOut, address(this));
        require(amountRecieved >= amountOut, "Swap failed");
        return;
    }

    function acceptableLoss(uint256 amountIn, uint256 amountOut) internal view returns(bool) {
        if(amountOut > amountIn) return true;
        return amountIn - amountOut < amountIn * maxExchangeLoss / 10000;
    }

    function repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
        return;
    }

    function withdraw(uint shares) external returns(uint amount) {
        return amount;
    }

    function getDepositCapacity() public view returns(uint) {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            return params.maximumExpectedValue - params.expectedValue;
        else
            return 0;
    }

    function mintDebtTokens(uint amount) internal {
        (uint maxMintable, ,) = alchemist.getMintLimitInfo();
        if (amount > maxMintable) {
            //mint as much as possible.
            amount = maxMintable;
        }
        alchemist.mint(amount, address(this));
        //Mint Debt Tokens
        return;
    }
}