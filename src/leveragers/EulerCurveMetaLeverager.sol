pragma solidity 0.8.19;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/alchemist/IAlchemistV2.sol";
import "../interfaces/euler/IFlashLoan.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
import "../interfaces/uniswap/TransferHelper.sol";
import "../interfaces/curve/ICurveSwap.sol";
import {IStableMetaPool} from "../interfaces/curve/IStableMetaPool.sol";

contract EulerCurveMetaLeverager is ILeverager, Ownable {
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    address public flashLoan;
    address public debtSource;
    address public dexPool;
    int128 debtTokenCurveIndex;
    int128 underlyingTokenCurveIndex;
    uint256 slippage = 100; //1%
    uint256 maxExchangeLoss = 1000; //10%

    constructor(address _yieldToken, address _underlyingToken, address _debtToken, address _flashLoan, address _debtSource, address _dexPool, int128 _debtTokenCurveIndex, int128 _underlyingTokenCurveIndex) {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        flashLoan = _flashLoan;
        debtSource = _debtSource;
        dexPool = _dexPool;
        debtTokenCurveIndex = _debtTokenCurveIndex;
        underlyingTokenCurveIndex = _underlyingTokenCurveIndex;

    }

    function getDepositedBalance(address _depositor) external view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //last accrued weight appears to be unrealized credit denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        uint256 yieldTokens = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);
        return yieldTokens;
    }

    function getDebtBalance(address _depositor) external view returns(int256 amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (int256 debt,) = alchemist.accounts(_depositor);
        return debt;
    }

    function getRedeemableBalance(address _depositor) external view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        uint256 depositedUnderlyingTokens = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);

        (int256 debtTokens,) = alchemist.accounts(_depositor);
        uint256 debtYieldTokens;
        if(debtTokens>0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtTokens));
            return depositedUnderlyingTokens - underlyingDebt;
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(-1*debtTokens));
            return depositedUnderlyingTokens + underlyingCredit;
        }
    }

    function withdrawUnderlying(uint amount) external {
        require(amount>0);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //need to calculate shares
        uint256 shares = 0;
        alchemist.withdrawUnderlying(yieldToken, shares, msg.sender, amount);
        require(false, "Not yet implemented");
    }

    function leverage(uint depositAmount, uint minDepositAmount) external {
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
            Markets markets = Markets(flashLoan);
            address dTokenAddress = markets.underlyingToDToken(underlyingToken);
            DToken dToken = DToken(dTokenAddress);
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
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IERC20(yieldToken).approve(address(alchemist), amount);
        alchemist.depositUnderlying(yieldToken, amount, address(this), minAmountOut);
    }

    function swapDebtTokens(uint amount) internal {
        ICurveSwap curveSwap = ICurveSwap(dexPool);
        (, uint256 amountOut) = curveSwap.getBestRate(debtToken, underlyingToken, amount);
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
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            return params.maximumExpectedValue - params.expectedValue;
        else
            return 0;
    }

    function mintDebtTokens(uint amount) internal {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
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