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

    constructor(address _yieldToken, address _underlyingToken, address _debtToken, address _flashLoan, address _debtSource, address _dex) {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        flashLoan = _flashLoan;
        debtSource = _debtSource;
        dex = _dex;
    }

    //return amount denominated in underlying tokens
    function getDepositedBalance(address _depositor) public view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //last accrued weight appears to be unrealized credit denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        amount = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);
    }

    //return amount denominated in debt tokens
    function getDebtBalance(address _depositor) public view returns(int256 amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (amount,) = alchemist.accounts(_depositor);
    }

    //return amount denominated in underlying tokens
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

    //return amount denominated in debt tokens
    function getMintableBalance(address _depositor) public view returns(uint amount) {
        require(false, "Not yet implemented");
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
    /// @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token. Does not account for yield peg deviations.
    /// @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token. Does not account for debt peg deviations.
    ///
    function leverage(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external {
        uint depositCapacity = getDepositCapacity();
        require(depositCapacity > 0, "Vault is full");
        require(depositAmount > 0, "Deposit amount must be greater than 0");

        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), depositAmount);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);

        uint256 underlyingCapacity = alchemist.convertYieldTokensToUnderlying(yieldToken, depositCapacity);
        if(underlyingCapacity < depositAmount) {
            // Vault can't hold all the deposit pool. Fill up the pool.
            depositAmount = underlyingCapacity;
            //minDepositAmount is denominated in yieldTokens
            uint256 minDepositAmount = _acceptableTradeOutput(alchemist.convertUnderlyingTokensToYield(yieldToken, depositAmount), underlyingSlippageBasisPoints);
            console.log("Deposit amount: ", depositAmount);
            console.log("Min deposit amount: ", minDepositAmount);
            console.log("Basic deposit");
            _depositUnderlying(depositAmount, minDepositAmount, msg.sender);
            return;            
        }
        else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            uint flashLoanAmount = _calculateFlashLoanAmount(dTokenAddress, depositAmount, debtSlippageBasisPoints, depositCapacity);
            bytes memory data = abi.encode(msg.sender, flashLoanAmount, depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
            dToken.flashLoan(flashLoanAmount, data);
            return;
        }
    }

    function onFlashLoan(bytes memory data) external {
        (address sender, uint flashLoanAmount, uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) = abi.decode(data, (address, uint, uint, uint32, uint32));

        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        uint totalDeposit = flashLoanAmount + depositAmount;
        uint256 minDepositAmount = _acceptableTradeOutput(alchemist.convertUnderlyingTokensToYield(yieldToken, totalDeposit), underlyingSlippageBasisPoints);
        console.log("Depositing");
        uint depositedShares = _depositUnderlying(totalDeposit, minDepositAmount, sender);
        // we should be able to mint at least half what we deposited
        // but we can actually mint more if we've accumulated credit since last leverage call
        uint redeemable = getDepositedBalance(sender);// - getDebtBalance(address(this));
        console.log("Redeemable:   ", redeemable/2);
        console.log("Flash amount: ", flashLoanAmount);
        _mintDebtTokens(redeemable, sender);
        console.log("Minted:       ", IERC20(debtToken).balanceOf(address(this)));
        _swapDebtTokens(redeemable/2, debtSlippageBasisPoints);
        console.log("Swapped");
        _repayFlashLoan(flashLoanAmount);
    }

    function _depositUnderlying(uint amount, uint minAmountOut, address sender_) internal returns(uint shares) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IERC20(underlyingToken).approve(address(alchemist), amount);
        uint depositedShares = alchemist.depositUnderlying(yieldToken, amount, sender_, minAmountOut);
        emit DepositUnderlying(underlyingToken, amount, alchemist.convertSharesToUnderlyingTokens(yieldToken, depositedShares));
    }

    function _getDTokenAddress() internal returns (address dTokenAddress) {
        Markets markets = Markets(flashLoan);
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
    }

    /*  This is going to be a meaty calculation.
        All we are using to repay the flashloan is the exchanged debt
        We can always flash loan more than we need but the idea is to deposit everything we flash loan
        This means we need to flash loan less than the amount to be deposited (slippage)
        Further we need to account for existing credit (which lets us flash more)
        And account for debt peg deviation + debt to underlying slippage
        The amountToFlashloan=mintableDebtAfterDeposit*debtToUnderlyingTradeRatio*slippageRatio
        mintableDebtAfterDeposit=mintableDebtBeforeDeposit+changeInMintableDebtFromDeposit
        changeInMintableDebtFromDeposit=#NYI

        e.g. deposit 10 ETH
        plan would be to flashloan 10 ETH but the slippage is 1% so we only get 19.8 ETH of credit
        Further the alETH peg is at .98 so despite being able to mint 9.9 alETH
        We only get 9.702 wETH out pre-slippage.
        With another 1% trade slippage we're at 9.60498 wETH we can use to repay the flashloan.
        Obviously if you borrowed 10, 9.60498 isn't enough to repay that.
        So we have to borrow less.

        We need to follow the algebra above to basically calculate the entire expected flow right here
        Then pass those values down through the stack as the minOutput values to depositUnderlying and exchange
    */
    function _calculateFlashLoanAmount(address dTokenAddress, uint depositAmount, uint32 debtSlippageBasisPoints, uint depositCapacity) internal returns (uint flashLoanAmount) {
        //Calculate flashloan amount. Amount flashed is less a % from total to account for slippage.
        flashLoanAmount = (depositAmount - (depositAmount/debtSlippageBasisPoints)) + depositAmount < depositCapacity 
            ? (depositAmount - (depositAmount/10))
            : depositCapacity - depositAmount;
    }

    //amount denominated in debt tokens
    function _swapDebtTokens(uint amount, uint32 debtSlippageBasisPoints) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);

        address swapTo = underlyingToken == weth ? curveEth : underlyingToken;
        
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(debtToken, swapTo, amount);
        //what we'd really like to know is the rate without slippage
        //then we adjust for slippage ourselves.
        //normalizeDebtTokensToUnderlying doesn't actually look at Curve
        //I don't know where _underlyingTokens[underlyingToken].conversionFactor comes from.
        uint minAmount = _acceptableTradeOutput(alchemist.normalizeDebtTokensToUnderlying(underlyingToken, amount), debtSlippageBasisPoints);
        require(amountOut>=minAmount, "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint256 amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmount, address(this));
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _acceptableTradeOutput(uint256 amountIn, uint32 slippageBasisPoints) internal view returns(uint256) {
        return amountIn * (10000-slippageBasisPoints) / 10000;
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