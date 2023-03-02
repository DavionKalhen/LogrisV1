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

    event DebugValue(uint256);

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

    //return amount denominated in yield tokens
    function getDepositCapacity() public view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            amount = params.maximumExpectedValue - params.expectedValue;
        else
            amount = 0;
    }

    //return amount denominated in debt tokens
    function getMintCapacity(address _depositor) public view returns(uint amount) {
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
            console.log("vault capacity smaller than deposit");
            // Vault can't hold all the deposit pool. Fill up the pool.
            depositAmount = underlyingCapacity;
            //minDepositAmount is denominated in yieldTokens
            uint256 minDepositAmount = _acceptableTradeOutput(alchemist.convertUnderlyingTokensToYield(yieldToken, depositAmount), underlyingSlippageBasisPoints);
            console.log("Basic deposit");
            _depositUnderlying(depositAmount, minDepositAmount, msg.sender);
            return;            
        }
        else {
            address dTokenAddress = _getDTokenAddress();
            DToken dToken = DToken(dTokenAddress);
            uint flashLoanAmount = _calculateFlashLoanAmount(depositAmount, debtSlippageBasisPoints, depositCapacity);
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

    function _depositUnderlying(uint amount, uint minAmountOut, address _sender) internal returns(uint shares) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        IERC20(underlyingToken).approve(address(alchemist), amount);
        emit DebugValue(amount);
        emit DebugValue(minAmountOut);
        emit DebugValue(getDepositCapacity());
        //[FAIL. Reason: Custom Error a3528cf5:(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 7193215267764540062, 3007188626873261449724)]
        //parameter 1 is the yield token address
        //parameter 2 is the shares returned
        //parameter 3 might be the capacity but I've tried overriding amount on deposit to very small values and it still fails.
        uint depositedShares = alchemist.depositUnderlying(yieldToken, amount, _sender, minAmountOut);
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
        The flashloanAmount=mintableDebtAfterDeposit*debtToUnderlyingTradeRatio*slippage
        mintableDebtAfterDeposit=mintableDebtBeforeDeposit+changeInMintableDebtFromDeposit
        changeInMintableDebtFromDeposit=(depositAmount+flashloanAmount)*underlyingToYieldTradeRatio*slippage/2

        e.g. deposit 10 ETH
        plan would be to flashloan 10 ETH but the slippage is 1% so we only get 19.8 ETH of credit
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
        receive (amount+X)*underlyingSlippage credit                    .99*(10+x)
        borrow ((amount+X)*underlyingSlippage)/2+credit alETH           (.99*(10+x)/2)+credit
        trade borrow alETH for debtToUnderlyingRatio*debtSlippage       .99*.98*((.99*(10+x)/2)+credit)
        repay Y ETH
        amount borrowed = X
        amount repayed = Y
        Y=X

        debtTradeLoss = debtToUnderlyingRatio * debtSlippage
        depositTradeLoss = underlyingSlippage
        totalTradeLoss = debtTradeLoss*depositTradeLoss

        x=.99*.98*((.99*(10+x)/2)+credit),                          read as debtTradeLoss * (depositLoss*deposit+credit)
        x=.99*.98*.99*(10+x)/2+.99*.98*credit                       multiplying the debtTradeLoss loss into deposit and credit
        x=(.99*.98*.99*10+.99*.98*.99*x)/2+.99*.98*credit           multiplying the depositTradeLoss into the deposit and flash loan values
        2x=(2*.99*.98*.99*10)+(.99*.98*.99*x)+2*.99*.98*credit      multipying by 2
        2x-(.99*.98*.99*x)=(2*.99*.98*.99*10)+2*.99*.98*credit      moved x from rhs to lhs
        (2-(.99*.98*.99))*x=(2*.99*.98*.99*10)+2*.99*.98*credit     factor x out
        x=((2*.99*.98*.99*10)+2*.99*.98*credit)/(2-(.99*.98*.99))   divide to solve for x

        flashLoanAmount = 2*(totalTradeLoss*depositAmount+debtTradeLoss*credit)/(2-totalTradeLoss)
        minDepositUnderlyingAmount = (depositAmount+flashLoanAmount)*underlyingSlippage
        mintAmount = (minDepositUnderlyingAmount/2)+credit
        minDebtTradeAmount = mintAmount*debtToUnderlyingRatio*debtSlippage

        return all these and use them for the remainder of the flow
    */
    function _calculateFlashLoanAmount(uint depositAmount, uint32 debtSlippageBasisPoints, uint depositCapacity) internal returns (uint flashLoanAmount) {
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