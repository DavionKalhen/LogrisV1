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
import "../interfaces/curve/ICurveFactory.sol";
//import conosle log
import "forge-std/console.sol";

contract EulerCurveMetaLeverager is ILeverager, Ownable {
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    address public flashLoan;
    address public debtSource;
    address public dex;
    address constant curveEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 slippage = 100; //1%
    uint256 maxExchangeLoss = 1000; //10%
    address sender;

    constructor(address _yieldToken, address _underlyingToken, address _debtToken, address _flashLoan, address _debtSource, address _dex) {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        flashLoan = _flashLoan;
        debtSource = _debtSource;
        dex = _dex;
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

    /// @dev Fills up as much vault capacity as possible using leverage.
    ///
    /// @param depositAmount Max amount of underlying token to use as the base deposit
    /// @param minDepositAmount Minimum amount of yield tokens added to vault post wrap
    ///
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
            minDepositAmount = minDepositAmount * depositCapacity / depositAmount;
            depositAmount = depositCapacity;
            console.log("Deposit amount: ", depositAmount);
            console.log("Min deposit amount: ", minDepositAmount);
        }

        else {
            //Calculate flashloan amount. Amount flashed is less a % from total to account for slippage.
            Markets markets = Markets(flashLoan);
            address dTokenAddress = markets.underlyingToDToken(underlyingToken);
            DToken dToken = DToken(dTokenAddress);
            uint flashLoanAmount = (depositAmount - (depositAmount/slippage)) + depositAmount < depositCapacity 
                ? (depositAmount - (depositAmount/10))
                : depositCapacity - depositAmount;

            sender = msg.sender;
            dToken.flashLoan(flashLoanAmount, abi.encodePacked(flashLoanAmount, depositAmount, minDepositAmount));
            return;
        }
        console.log("Basic deposit");
        _depositUnderlying(depositAmount, minDepositAmount, msg.sender);
        return;
    }

    function onFlashLoan(bytes memory data) external {
        (uint flashLoanAmount, uint depositAmount, uint minDepositAmount) = abi.decode(data, (uint, uint, uint));
        console.log("Depositing");
        _depositUnderlying(flashLoanAmount + depositAmount, minDepositAmount + (flashLoanAmount - (flashLoanAmount/slippage)), sender);
        uint redeemable = getDepositedBalance(sender);// - getDebtBalance(address(this));
        console.log("Redeemable:   ", redeemable/2);
        console.log("Flash amount: ", flashLoanAmount);
        _mintDebtTokens(redeemable, sender);
        console.log("Minted:       ", IERC20(debtToken).balanceOf(address(this)));
        _swapDebtTokens(redeemable/2);
        console.log("Swapped");
        _repayFlashLoan(flashLoanAmount);
        sender = address(0);
    }

    function _depositUnderlying(uint amount, uint minAmountOut, address sender_) internal {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IERC20(underlyingToken).approve(address(alchemist), amount);
        uint depositedShares = alchemist.depositUnderlying(yieldToken, amount, sender_, minAmountOut);
        emit DepositUnderlying(underlyingToken, amount, alchemist.convertSharesToUnderlyingTokens(yieldToken, depositedShares));
    }

    function _swapDebtTokens(uint amount) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapTo = underlyingToken == weth ? curveEth : underlyingToken;
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(debtToken, swapTo, amount);
        uint minAmount = _acceptableTradeOutput(amount);
        require(amountOut>=minAmount, "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint256 amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmount, address(this));
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _acceptableTradeOutput(uint256 amountIn) internal view returns(uint256) {
        return amountIn * maxExchangeLoss / 10000;
    }

    function _repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
        return;
    }

    function withdraw(uint shares) external returns(uint amount) {
        require(false, "Not yet implemented");
    }

    function getDepositCapacity() public view returns(uint) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            return params.maximumExpectedValue - params.expectedValue;
        else
            return 0;
    }

    function _mintDebtTokens(uint amount, address sender_) internal {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (uint maxMintable, ,) = alchemist.getMintLimitInfo();
        if (amount > maxMintable) {
            //mint as much as possible.
            amount = maxMintable;
        }
        //Mint Debt Tokens
        alchemist.mintFrom(sender_, amount/2, address(this));
        emit Mint(yieldToken, amount);
        return;
    }

    fallback() external payable {
        IWETH(weth).deposit{value: msg.value}();
        console.log("WETH deposited");
        console.log(msg.value);
    }
}