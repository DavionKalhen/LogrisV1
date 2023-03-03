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
    address public debtSource;
    address public dex;
    address constant curveEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

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
        //last accrued weight appears to be unrealized borrowCapacity denominated in debt tokens
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
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            amount = params.maximumExpectedValue - params.expectedValue;
        else
            amount = 0;
    }

    //return amount denominated in debt tokens
    function getBorrowCapacity(address _depositor) public view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
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

    //gets the withdraw capacity of the vault without liquidation
    //see getRedeemableBalance for the withdraw capacity with liquidation
    function getWithdrawCapacity(address _depositor) public view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        uint256 minimumCollateralization = alchemist.minimumCollateralization();//includes 1e18

        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        uint clampedDebt = (debtBalance<=0) ? 0: uint(debtBalance);

        amount = depositBalance - (alchemist.normalizeDebtTokensToUnderlying(underlyingToken, clampedDebt) * minimumCollateralization / FIXED_POINT_SCALAR);
    }

    /// @dev Fills up as much vault capacity as possible using leverage.
    ///
    /// @param depositAmount Max amount of underlying token to use as the base deposit
    /// @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token. Must include basis points for peg deviations.
    /// @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token. Does not account for debt peg deviations.
    ///
    function leverage(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) external {
        uint depositCapacity = getDepositCapacity();
        require(depositCapacity > 0, "Vault is full");
        require(depositAmount > 0, "Deposit amount must be greater than 0");

        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), depositAmount);

        if(depositCapacity < depositAmount) {
            console.log("vault capacity smaller than deposit");
            // Vault can't hold all the deposit pool. Fill up the pool.
            depositAmount = depositCapacity;
            console.log("Basic deposit");
            _depositUnderlying(depositAmount, underlyingSlippageBasisPoints, msg.sender);
        }
        else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            (uint flashLoanAmount, uint mintAmount) = _calculateFlashLoanAmount(depositAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints, depositCapacity);
            //approve mint needs to be called before msg.sender changes
            //requires change to delegate call first. this is prep work.
            //alchemist.approveMint(address, amount);
            bytes memory data = abi.encode(msg.sender, flashLoanAmount, depositAmount, mintAmount, underlyingSlippageBasisPoints, debtSlippageBasisPoints);
            dToken.flashLoan(flashLoanAmount, data);
        }
        //the dust should get transmitted back to msg.sender but it might not be worth the gas...
        //better solved with a delegate call pattern but that would stop the leverager from
        //working with EOA accounts
    }

    function onFlashLoan(bytes memory data) external {
        (address sender, uint flashLoanAmount, uint depositAmount, uint mintAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints) = abi.decode(data, (address, uint, uint, uint, uint32, uint32));
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to ourselves
        //if we also refactor to a delegate call design
        console.log("msg.sender:", msg.sender);
        console.log("sender:", sender);
        require(msg.sender==flashLoan, "callback caller must be flashloan source");
        uint totalDeposit = flashLoanAmount + depositAmount;
        _depositUnderlying(totalDeposit, underlyingSlippageBasisPoints, sender);
        _mintDebtTokens(mintAmount, sender);
        _swapDebtTokens(mintAmount, debtSlippageBasisPoints);
        _repayFlashLoan(flashLoanAmount);
    }

    function _depositUnderlying(uint amount, uint32 underlyingSlippageBasisPoints, address _sender) internal returns(uint shares) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        uint minAmountOut = _basisPointAdjustment(alchemist.convertUnderlyingTokensToYield(yieldToken, amount), underlyingSlippageBasisPoints);
        IERC20(underlyingToken).approve(address(alchemist), amount);
        console.log("Deposit underlying: ", amount);
        shares = alchemist.depositUnderlying(yieldToken, amount, _sender, minAmountOut);
        emit DepositUnderlying(underlyingToken, amount, alchemist.convertSharesToUnderlyingTokens(yieldToken, shares));
    }

    function _getDTokenAddress() internal view returns (address dTokenAddress) {
        Markets markets = Markets(flashLoan);
        dTokenAddress = markets.underlyingToDToken(underlyingToken);
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

        x=debtTradeLoss*((underlyingSlippage*(deposit+x)/2)+borrowCapacity),                read as debtTradeLoss * (borrowAmountFromDeposits+existingBorrowCapacity)
        x=totalTradeLoss*(deposit+x)/2+debtTradeLoss*borrowCapacity                         multiplying the debtTradeLoss loss into deposit and borrowCapacity
        x=(totalTradeLoss*deposit+totalTradeLoss*x)/2+debtTradeLoss*borrowCapacity          multiplying the depositTradeLoss into the deposit and flash loan values
        2x=(totalTradeLoss*deposit)+(totalTradeLoss*x)+2*debtTradeLoss*borrowCapacity     multipying by 2
        2x-(totalTradeLoss*x)=(totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity     moved x from rhs to lhs
        (2-totalTradeLoss)*x=(totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity      factor x out
        x=((totalTradeLoss*deposit)+2*debtTradeLoss*borrowCapacity)/(2-(totalTradeLoss))  divide to solve for x

        flashLoanAmount = ((totalTradeLoss*depositAmount)+(collateralizationRatio*debtTradeLoss*borrowCapacity))/(collateralizationRatio-totalTradeLoss)
        minDepositUnderlyingAmount = (depositAmount+flashLoanAmount)*underlyingSlippage
        mintAmount = (minDepositUnderlyingAmount/2)+borrowCapacity
        minDebtTradeAmount = mintAmount*debtToUnderlyingRatio*debtSlippage
    */
    function _calculateFlashLoanAmount(uint depositAmount, uint32 underlyingSlippageBasisPoints, uint32 debtSlippageBasisPoints, uint depositCapacity) internal view returns (uint flashLoanAmount, uint mintAmount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //normalizeDebt is returning 1:1 despite the alETH peg being .97
        //We would need to get the actual price per token from our curve factory.
        //I think we can just bundle the peg deviation with the slippage into debtSlippageBasisPoints and save the gas.
        uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);
        uint totalTradeLoss = _basisPointAdjustment(debtTradeLoss, underlyingSlippageBasisPoints);
        uint borrowCapacity = getBorrowCapacity(msg.sender);
        uint256 minimumCollateralization = alchemist.minimumCollateralization();
        console.log("debt trade loss: ", debtTradeLoss);
        console.log("total trade loss: ", totalTradeLoss);
        console.log("borrowCapacity:", borrowCapacity);
        console.log("minimumCollateralization:", minimumCollateralization);

        flashLoanAmount = ((totalTradeLoss*depositAmount)+(minimumCollateralization*debtTradeLoss*borrowCapacity/1e18))/(minimumCollateralization-totalTradeLoss);
        console.log("flashLoanAmount: ", flashLoanAmount);
        if(depositAmount+flashLoanAmount>depositCapacity) {
            flashLoanAmount = depositCapacity-depositAmount;
        }

        mintAmount = _calculateMintAmount(depositAmount+flashLoanAmount, underlyingSlippageBasisPoints, borrowCapacity, minimumCollateralization);
        console.log("mint amount:", mintAmount);
    }

    function _calculateMintAmount(uint totalDeposit, uint32 underlyingSlippageBasisPoints, uint borrowCapacity, uint minimumCollateralization) internal pure returns(uint mintAmount) {
        mintAmount = borrowCapacity + _basisPointAdjustment(totalDeposit, underlyingSlippageBasisPoints) * FIXED_POINT_SCALAR / minimumCollateralization;
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
        uint minAmount = _basisPointAdjustment(alchemist.normalizeDebtTokensToUnderlying(underlyingToken, amount), debtSlippageBasisPoints);
        require(amountOut>=minAmount, "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint256 amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmount, address(this));
        console.log("Swapped: ", amount, amountReceived);
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _basisPointAdjustment(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000-slippageBasisPoints) / 10000;
    }

    function _basisPointAdjustmentUp(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000+slippageBasisPoints) / 10000;
    }

    function _repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
        return;
    }

    //Just like with leverage we need to calculate whether we can withdraw without liquidating
    function withdrawUnderlying(uint amount, uint32 underlyingSlippageBasisPoints) external returns(uint withdrawnAmount) {
        require(amount>0);
        uint withdrawCapacity = getWithdrawCapacity(msg.sender);
        console.log("withdraw capacity: ", withdrawCapacity);
        if(amount<withdrawCapacity) {
            console.log("simple withdraw");
            withdrawnAmount = _withdrawUnderlying(amount, underlyingSlippageBasisPoints, msg.sender);
        } else {
            require(false, "Not yet implemented");
        }
    }

    function _withdrawUnderlying(uint amount, uint32 underlyingSlippageBasisPoints, address recipient) internal returns(uint withdrawnAmount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        uint adjustedUnderlying = _basisPointAdjustmentUp(amount, underlyingSlippageBasisPoints);
        uint shares = alchemist.convertUnderlyingTokensToShares(yieldToken, adjustedUnderlying);
        withdrawnAmount = alchemist.withdrawUnderlyingFrom(recipient, yieldToken, shares, recipient, amount);
    }

    function _mintDebtTokens(uint mintAmount, address _sender) internal {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
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

    fallback() external payable {
        IWETH(weth).deposit{value: msg.value}();
        console.log("WETH deposited");
        console.log(msg.value);
    }
}