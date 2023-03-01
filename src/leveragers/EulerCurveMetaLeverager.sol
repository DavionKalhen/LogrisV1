pragma solidity 0.8.19;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/wETH/IWETH.sol";
import "../interfaces/alchemist/IAlchemistV2.sol";
import "../interfaces/alchemist/ITokenAdapter.sol";
import "../interfaces/euler/IFlashLoan.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
import "../interfaces/uniswap/TransferHelper.sol";
import "../interfaces/curve/ICurveSwap.sol";
import "../interfaces/curve/ICurvePool.sol";
//import conosle log
import "forge-std/console.sol";
import {IStableMetaPool} from "../interfaces/curve/IStableMetaPool.sol";

contract EulerCurveMetaLeverager is ILeverager, Ownable {
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    address public flashLoan;
    address public debtSource;
    address public dexPool;
    address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
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

    function getDepositedBalance(address _depositor) public view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //last accrued weight appears to be unrealized credit denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        amount = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);
    }

    function getDebtBalance(address _depositor) public view returns(int256 amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (amount,) = alchemist.accounts(_depositor);
    }

    function getRedeemableBalance(address _depositor) public view returns(uint amount) {
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

        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), depositAmount);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);

        IAlchemistV2.UnderlyingTokenParams memory underlyingParams = alchemist.getUnderlyingTokenParameters(underlyingToken);
        IAlchemistV2.YieldTokenParams memory yieldParams = alchemist.getYieldTokenParameters(yieldToken);
        ITokenAdapter adapter = ITokenAdapter(yieldParams.adapter);
        uint256 priceAdjustedDepositAmount = depositAmount * adapter.price() / 10**underlyingParams.decimals;
        if(priceAdjustedDepositAmount > depositCapacity) {
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
        uint redeemable = getDepositedBalance(address(this));// - getDebtBalance(address(this));
        console.log("redeemable:   ", redeemable/2);
        console.log("Flash amount: ", flashLoanAmount);
        mintDebtTokens(redeemable);
        console.log("Minted:       ", IERC20(debtToken).balanceOf(address(this)));
        swapDebtTokens(redeemable/2);
        console.log("Swapped");
        repayFlashLoan(flashLoanAmount);
    }

    function depositUnderlying(uint amount, uint minAmountOut) internal {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IERC20(underlyingToken).approve(address(alchemist), amount);
        alchemist.depositUnderlying(yieldToken, amount, address(this), minAmountOut);
    }

    function swapDebtTokens(uint amount) internal {
        ICurveSwap curveSwap = ICurveSwap(dexPool);
        address swapTo = underlyingToken == weth ? 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE : underlyingToken;
        (address pool, uint256 amountOut) = curveSwap.get_best_rate(debtToken, swapTo, amount);
        require(acceptableLoss(amount, amountOut), "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(pool, amount);
        uint256 amountRecieved = ICurvePool(pool).exchange(1, 0, amount, 1);
        require(amountRecieved >= 1, "Swap failed");
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
        
        alchemist.mint(amount/2, address(this));
        //Mint Debt Tokens
        return;
    }
    fallback() external payable {
        IWETH(weth).deposit{value: msg.value}();
        console.log("WETH deposited");
        console.log(msg.value);
    }
}