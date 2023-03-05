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
//import console log
import "forge-std/console.sol";

contract EulerCurveMetaLeverager is ILeverager, Ownable {
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    address public flashLoan;
    address public flashLoanSender;//will be replaced by a calculation eventually
    address public debtSource;
    address public dex;
    IAlchemistV2 alchemist;
    
    address constant curveEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FIXED_POINT_SCALAR = 1e18;

    constructor(address _yieldToken, address _underlyingToken, address _debtToken, address _flashLoan, address _flashLoanSender, address _debtSource, address _dex) {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        flashLoan = _flashLoan;
        flashLoanSender = _flashLoanSender;
        debtSource = _debtSource;
        dex = _dex;
        alchemist = IAlchemistV2(debtSource);
    }

    //return amount denominated in underlying tokens
    function getDepositedBalance(address _depositor) public view returns(uint amount) {
        //last accrued weight appears to be unrealized borrowCapacity denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        amount = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);
    }

    //return amount denominated in debt tokens
    function getDebtBalance(address _depositor) public view returns(int256 amount) {
        (amount,) = alchemist.accounts(_depositor);
    }

    //return amount denominated in underlying tokens
    function getRedeemableBalance(address _depositor) public view returns(uint amount) {
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        if(debtBalance>=0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtBalance));
            return depositBalance - underlyingDebt;
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(-1*debtBalance));
            return depositBalance + underlyingCredit;
        }
    }

    //return amount denominated in underlying tokens
    function getDepositCapacity() public view returns(uint amount) {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            amount = params.maximumExpectedValue - params.expectedValue;
        else
            amount = 0;
    }

    //return amount denominated in debt tokens
    function getBorrowCapacity(address _depositor) public view returns(uint amount) {
        uint256 minimumCollateralization = alchemist.minimumCollateralization();//includes 1e18
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        uint debtAdjustedBalance=0;
        if(debtBalance>=0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtBalance));
            debtAdjustedBalance = depositBalance - (underlyingDebt * minimumCollateralization / FIXED_POINT_SCALAR);
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(-1*debtBalance));
            debtAdjustedBalance = depositBalance + (underlyingCredit * minimumCollateralization / FIXED_POINT_SCALAR);
        }
        amount = debtAdjustedBalance * FIXED_POINT_SCALAR / minimumCollateralization;
    }

    function getTotalWithdrawCapacity(address _depositor) public view returns (uint shares) {
        (shares,) = alchemist.positions(_depositor, yieldToken);
        return shares;
    }

    //gets the withdraw capacity of the vault without liquidation
    function getFreeWithdrawCapacity(address _depositor) public view returns(uint shares) {
        uint256 minimumCollateralization = alchemist.minimumCollateralization();//includes 1e18

        (uint256 totalShares,) = alchemist.positions(_depositor, yieldToken);
        int256 debtBalance = getDebtBalance(_depositor);
        uint clampedDebt = (debtBalance<=0) ? 0: uint(debtBalance);
        uint debtShares = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, clampedDebt) * minimumCollateralization / FIXED_POINT_SCALAR;

        shares = totalShares - debtShares;
    }

    /*  This is going to be a meaty calculation.
        All we are using to repay the flashloan is the exchanged debt
        We can always flash loan more than we need but the idea is to deposit everything we flash loan
        This means we need to flash loan less than the amount to be deposited (slippage)
        Further we need to account for existing borrowCapacity (which lets us flash more)
        And account for debt peg deviation + debt to underlying slippage
        The flashloanAmount=mintableDebtAfterDeposit*debtToUnderlyingTradeRatio*slippage
        mintableDebtAfterDeposit=mintableDebtBeforeDeposit+changeInMintableDebtFromDeposit
        changeInMintableDebtFromDeposit=(depositAmount+flashloanAmount)*underlyingToYieldTradeRatio*slippage/2

        e.g. deposit 10 ETH
        plan would be to flashloan 10 ETH but the slippage is 1% so we only get 19.8 ETH of borrowCapacity
        Further the alETH peg is at .98 so despite being able to mint 9.9 alETH
        We only get 9.702 wETH out pre-slippage.
        With another 1% trade slippage we're at 9.60498 wETH we can use to repay the flashloan.
        Obviously if you borrowed 10, 9.60498 isn't enough to repay that.
        So we have to borrow less.

        We need to follow the algebra above to basically calculate the entire expected flow right here
        Then pass those values down through the stack as the minOutput values to depositUnderlying and exchange
        e.g.
        deposit amount ETH                                              10
        borrow X ETH
        deposit amount+X ETH                                            10+x
        receive (amount+X)*underlyingSlippage borrowCapacity                    .99*(10+x)
        borrow ((amount+X)*underlyingSlippage)/2+borrowCapacity alETH           (.99*(10+x)/2)+borrowCapacity
        trade borrow alETH for debtToUnderlyingRatio*debtSlippage       .99*.98*((.99*(10+x)/2)+borrowCapacity)
        repay Y ETH
        amount borrowed = X
        amount repayed = Y
        Y=X

        debtTradeLoss = debtToUnderlyingRatio * debtSlippage
        depositTradeLoss = underlyingSlippage
        totalTradeLoss = debtTradeLoss*depositTradeLoss

        x=debtTradeLoss*((underlyingSlippage*(deposit+x)/2)+borrowCapacity),              read as debtTradeLoss * (borrowAmountFromDeposits+existingBorrowCapacity)
        x=totalTradeLoss*(deposit+x)/2+debtTradeLoss*borrowCapacity                       multiplying the debtTradeLoss loss into deposit and borrowCapacity
        x=(totalTradeLoss*deposit+totalTradeLoss*x)/2+debtTradeLoss*borrowCapacity        multiplying the depositTradeLoss into the deposit and flash loan values
        2x=(totalTradeLoss*deposit)+(totalTradeLoss*x)+2*debtTradeLoss*borrowCapacity     multipying by 2
        2x-(totalTradeLoss*x)=(totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity     moved x from rhs to lhs
        (2-totalTradeLoss)*x=(totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity      factor x out
        x=((totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity)/(2-(totalTradeLoss))  divide to solve for x

        flashLoanAmount = ((totalTradeLoss*depositAmount)+(collateralizationRatio*debtTradeLoss*borrowCapacity))/(collateralizationRatio-totalTradeLoss)
        minDepositUnderlyingAmount = (depositAmount+flashLoanAmount)*underlyingSlippage
        mintAmount = (minDepositUnderlyingAmount/2)+borrowCapacity
        minDebtTradeAmount = mintAmount*debtToUnderlyingRatio*debtSlippage
    */
    function getLeverageParameters(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) public view returns(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) {
        uint depositCapacity = getDepositCapacity();
        if(depositCapacity <= depositAmount) {
            clampedDeposit = depositCapacity;
            underlyingDepositMin = _basisPointAdjustment(alchemist.convertUnderlyingTokensToYield(yieldToken, clampedDeposit), underlyingSlippageBasisPoints);
        }
        else {
            clampedDeposit = depositAmount;
            uint borrowCapacity = getBorrowCapacity(msg.sender);
            console.log("borrowCapacity:", borrowCapacity);
            flashLoanAmount = _calculateFlashLoanAmount(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints, borrowCapacity, alchemist.minimumCollateralization());
            console.log("flashLoanAmount: ", flashLoanAmount);
            if(depositAmount+flashLoanAmount>depositCapacity) {
                flashLoanAmount = depositCapacity-depositAmount;
            }
            //denominated in yield
            underlyingDepositMin = _basisPointAdjustment(alchemist.convertUnderlyingTokensToYield(yieldToken, depositAmount+flashLoanAmount), underlyingSlippageBasisPoints);
            console.log("underlying deposit min (in yield): ", underlyingDepositMin);
            mintAmount = borrowCapacity + (alchemist.convertYieldTokensToUnderlying(yieldToken, underlyingDepositMin) * FIXED_POINT_SCALAR / alchemist.minimumCollateralization());
            console.log("mint amount:", mintAmount);
            debtTradeMin =_basisPointAdjustment(mintAmount, debtSlippageBasisPoints);
        }
    }

    /*  While there is a liquidate call it can't be called on someone else's behalf which makes this more complicated.
        Unlike everything else on Alchemist there is no liquidateFrom so we have to flashloan to unwind the leverage.
        Basically this makes this the reverse of depositing with leverage.

        Assuming we have a withdraw share amount needed after shares available for withdraw:
        We need to repay repayAmount to free up withdrawShares
        e.g.
        flash loan X
        trade X for debt                                    receive flashLoanAmount*debtTradeLoss underlying
        burn debt freeing up Y shares                       receive debt*2 withdrawable      
        Withdraw Y shares to underlying                     receive withdrawable*underlyingSlippage underlying
        repay X, keep Y profit

        debtTradeLoss = debtToUnderlyingRatio * debtSlippage
        withdrawTradeLoss = underlyingSlippage

        To free Y shares, you need to burn debtAmount=Y*sharesPerUnderlying/collateralization 
        To get debtAmount you need to borrow flashLoanAmount*debtTradeLoss
        therefore Y*sharesPerUnderlying/collateralization = flashLoanAmount*debtTradeLoss
        flashLoanAmount=Y*sharesPerUnderlying/(collateralization*debtTradeLoss)
    */
    function getWithdrawParameters(uint shares, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) public view returns(uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) {
        uint freeShares = getFreeWithdrawCapacity(msg.sender);
        if(shares<=freeShares) {
            console.log("simple withdraw");
            minUnderlyingOut = _basisPointAdjustment(shares, underlyingSlippageBasisPoints);
        } else {
            uint remainingShares = shares-freeShares;
            uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);

            flashLoanAmount=alchemist.convertSharesToUnderlyingTokens(yieldToken, remainingShares)*1e36/(alchemist.minimumCollateralization()*debtTradeLoss);
            burnAmount = _basisPointAdjustment(flashLoanAmount, debtSlippageBasisPoints);
            debtTradeMin = burnAmount;
        }
    }

    /// @dev Fills up as much vault capacity as possible using leverage.
    ///
    /// @param depositAmount Max amount of underlying token to use as the base deposit
    /// @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token. Must include basis points for peg deviations.
    /// @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token. Does not account for debt peg deviations.
    ///
    function leverage(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external {
        (uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) = getLeverageParameters(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
        require(clampedDeposit > 0, "Vault is full");
        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), clampedDeposit);

        if(flashLoanAmount == 0) {
            console.log("Basic deposit");
            _depositUnderlying(clampedDeposit, underlyingDepositMin, msg.sender);
        } else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            bytes memory data = abi.encode(msg.sender, flashLoanSender, true, clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
            dToken.flashLoan(flashLoanAmount, data);
        }
        //the dust should get transmitted back to msg.sender but it might not be worth the gas...
    }

    // so its really tricky having to have a contract receive the same callback signature with two different callback flows...
    // as luck would have it deposit and withdraw have the same number of parameters on their callback
    function onFlashLoan(bytes memory data) external {
        (address sender, address flashLoanSender, bool depositFlag, uint param1, uint param2, uint param3, uint param4, uint param5) = abi.decode(data, (address, address, bool, uint, uint, uint, uint, uint));
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to the leverager
        console.log("msg.sender:", msg.sender);
        console.log("sender:", sender);
        console.log("flashLoanSender:", flashLoanSender);
        require(msg.sender==flashLoanSender, "callback caller must be flashloan source");
        if(depositFlag) {
            _flashLoanDeposit(sender, param1, param2, param3, param4, param5);
        } else {
            _flashLoanWithdraw(sender, param1, param2, param3, param4, param5);
        }
    }

    function _flashLoanDeposit(address sender, uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin) internal {
        uint totalDeposit = clampedDeposit + flashLoanAmount;
        _depositUnderlying(totalDeposit, underlyingDepositMin, sender);
        _mintDebtTokens(mintAmount, sender);
        _swapDebtTokens(mintAmount, debtTradeMin);
        _repayFlashLoan(flashLoanAmount);
    }

    function _calculateFlashLoanAmount(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints, uint borrowCapacity, uint minimumCollateralization) internal pure returns (uint flashLoanAmount) {
        //normalizeDebt is returning 1:1 despite the alETH peg being .97
        //We would need to get the actual price per token from our curve factory.
        //I think we can just bundle the peg deviation with the slippage into debtSlippageBasisPoints for now.
        uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);
        uint totalTradeLoss = _basisPointAdjustment(debtTradeLoss, underlyingSlippageBasisPoints);
        flashLoanAmount = ((totalTradeLoss*depositAmount)+(minimumCollateralization*debtTradeLoss*borrowCapacity/1e18))/(minimumCollateralization-totalTradeLoss);
    }

    function _getDTokenAddress() internal view returns (address dTokenAddress) {
        Markets markets = Markets(flashLoan);
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
    }

    function _depositUnderlying(uint amount, uint minAmountOut, address _sender) internal {
        IERC20(underlyingToken).approve(address(alchemist), amount);
        console.log("Deposit underlying: ", amount);
        uint shares = alchemist.depositUnderlying(yieldToken, amount, _sender, minAmountOut);
        emit DepositUnderlying(underlyingToken, amount, alchemist.convertSharesToUnderlyingTokens(yieldToken, shares));
    }

    function _mintDebtTokens(uint mintAmount, address _sender) internal {
        //this needs to be accountd for in calculate flash loan
        // (uint maxMintable, ,) = alchemist.getMintLimitInfo();
        // if (amount > maxMintable) {
        //     //mint as much as possible.
        //     amount = maxMintable;
        // }
        //Mint Debt Tokens
        alchemist.mintFrom(_sender, mintAmount, address(this));
        console.log("Minted: ", mintAmount);
        emit Mint(yieldToken, mintAmount);
        return;
    }

    //amount denominated in debt tokens
    function _swapDebtTokens(uint amount, uint minAmountOut) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapTo = underlyingToken == weth ? curveEth : underlyingToken;
        
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(debtToken, swapTo, amount);
        require(amountOut>=minAmountOut, "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmountOut, address(this));
        console.log("Swapped: ", amount, amountReceived);
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
        console.log("Repaid: ", amount);
        return;
    }

    function _basisPointAdjustment(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000-slippageBasisPoints) / 10000;
    }

    function _basisPointAdjustmentUp(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000+slippageBasisPoints) / 10000;
    }

    function withdrawUnderlying(uint shares, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external {
        require(shares>0, "must include shares to withdraw");
        require(getTotalWithdrawCapacity(msg.sender)<shares, "shares exceeds capacity");
        (uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) = getWithdrawParameters(shares, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
        if(burnAmount==0) {
            alchemist.withdrawUnderlyingFrom(msg.sender, yieldToken, shares, msg.sender, minUnderlyingOut);
        } else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            bytes memory data = abi.encode(msg.sender, flashLoanSender, false, shares, flashLoanAmount, burnAmount, debtTradeMin, minUnderlyingOut);
            dToken.flashLoan(flashLoanAmount, data);
        }
    }

    function _flashLoanWithdraw(address sender, uint shares, uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) internal {
        _swapToDebtTokens(flashLoanAmount, debtTradeMin);
        alchemist.burn(burnAmount, sender);
        alchemist.withdrawUnderlyingFrom(sender, yieldToken, shares, address(this), minUnderlyingOut);
        _repayFlashLoan(flashLoanAmount);
        IERC20 token = IERC20(underlyingToken);
        TransferHelper.safeTransfer(underlyingToken, sender, token.balanceOf(address(this)));
    }

    function _swapToDebtTokens(uint amount, uint minAmountOut) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapFrom = underlyingToken == weth ? curveEth : underlyingToken;
        
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(swapFrom, debtToken, amount);
        require(amountOut>=minAmountOut, "Swap exceeds max acceptable loss");
        IERC20(underlyingToken).approve(dex, amount);
        uint amountReceived = curveFactory.exchange(pool, debtToken, swapFrom, amount, minAmountOut, address(this));
        console.log("Swapped: ", amount, amountReceived);
        emit Swap(underlyingToken, debtToken, amount, amountReceived);
    }

    fallback() external payable {
        IWETH(weth).deposit{value: msg.value}();
        console.log("WETH deposited");
        console.log(msg.value);
    }
}