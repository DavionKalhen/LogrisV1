// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/wETH/IWETH.sol";
import "../interfaces/alchemist/IAlchemistV2.sol";
import "../interfaces/alchemist/ITokenAdapter.sol";
import "../interfaces/balancer/IFlashLoanRecipient.sol";
import "../interfaces/balancer/IVault.sol";
import "../interfaces/uniswap/TransferHelper.sol";
import "../interfaces/curve/ICurveFactory.sol";
//import console log
import "forge-std/console.sol";

contract BalancerCurveLeverager is ILeverager, Ownable, IFlashLoanRecipient{
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    address public flashLoan;
    address public debtSource;
    address public dex;
    IAlchemistV2 alchemist;
    IVault vault;
    
    address constant curveEth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant FIXED_POINT_SCALAR = 1e18;

    constructor(address _yieldToken,
    address _underlyingToken,
    address _debtToken,
    address _flashLoan,
    address _debtSource,
    address _dex)
    Ownable() {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        flashLoan = _flashLoan;
        debtSource = _debtSource;
        dex = _dex;
        alchemist = IAlchemistV2(debtSource);
        vault = IVault(flashLoan);
    }

    //return amount denominated in underlying tokens
    function getDepositedBalance(address _depositor) public view override returns(uint amount) {
        //last accrued weight appears to be unrealized borrowCapacity denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        amount = alchemist.convertSharesToUnderlyingTokens(yieldToken, shares);
    }

    //return amount denominated in debt tokens
    function getDebtBalance(address _depositor) public view override returns(int256 amount) {
        (amount,) = alchemist.accounts(_depositor);
    }

    //return amount denominated in underlying tokens
    function getRedeemableBalance(address _depositor) public view override returns(uint amount) {
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        if(debtBalance >= 0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtBalance));
            return depositBalance - underlyingDebt;
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken,
                                                                                 uint(-1 * debtBalance));
            return depositBalance + underlyingCredit;
        }
    }

    //return amount denominated in underlying tokens
    function getDepositCapacity() public view override returns(uint amount) {
        IAlchemistV2.YieldTokenParams memory params = alchemist.getYieldTokenParameters(yieldToken);
        if(params.maximumExpectedValue >= params.expectedValue)
            amount = params.maximumExpectedValue - params.expectedValue;
        else
            amount = 0;
    }

    //return amount denominated in debt tokens
    function getBorrowCapacity(address _depositor) public view override returns(uint amount) {
        uint256 minimumCollateralization = alchemist.minimumCollateralization();//includes 1e18
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        uint debtAdjustedBalance = 0;
        if(debtBalance >= 0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtBalance));
            debtAdjustedBalance = depositBalance - (underlyingDebt * minimumCollateralization / FIXED_POINT_SCALAR);
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken,
                                                                                 uint(-1 * debtBalance));
            debtAdjustedBalance = depositBalance + (underlyingCredit * minimumCollateralization / FIXED_POINT_SCALAR);
        }
        amount = debtAdjustedBalance * FIXED_POINT_SCALAR / minimumCollateralization;
    }

    function getTotalWithdrawCapacity(address _depositor) public view override returns (uint shares) {
        (shares,) = alchemist.positions(_depositor, yieldToken);
        return shares;
    }

    //gets the withdraw capacity of the vault without liquidation
    function getFreeWithdrawCapacity(address _depositor) public view override returns(uint shares) {
        uint256 minimumCollateralization = alchemist.minimumCollateralization();//includes 1e18

        (uint256 totalShares,) = alchemist.positions(_depositor, yieldToken);
        int256 debtBalance = getDebtBalance(_depositor);
        uint clampedDebt = (debtBalance<=0) ? 0: uint(debtBalance);
        uint debtShares = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, clampedDebt)
                          * minimumCollateralization / FIXED_POINT_SCALAR;

        shares = totalShares - debtShares;
    }

    //returns Alchemix shares
    function convertUnderlyingTokensToShares(uint256 amount) external view override returns (uint shares) {
        shares = alchemist.convertUnderlyingTokensToShares(yieldToken, amount);
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
    function getLeverageParameters(uint depositAmount,
                                   uint32 underlyingSlippageBasisPoints,
                                   uint32 debtSlippageBasisPoints) public view override returns(uint clampedDeposit,
                                                                                       uint flashLoanAmount,
                                                                                       uint underlyingDepositMin,
                                                                                       uint mintAmount,
                                                                                       uint debtTradeMin) {
        uint depositCapacity = getDepositCapacity();
        if(depositCapacity <= depositAmount) {
            clampedDeposit = depositCapacity;
            underlyingDepositMin = _basisPointAdjustment(
                alchemist.convertUnderlyingTokensToYield(yieldToken, clampedDeposit),
                underlyingSlippageBasisPoints);
        }
        else {
            clampedDeposit = depositAmount;
            uint borrowCapacity = getBorrowCapacity(msg.sender);
            console.log("borrowCapacity:", borrowCapacity);
            flashLoanAmount = _calculateFlashLoanAmount(depositAmount,
                                                        underlyingSlippageBasisPoints,
                                                        debtSlippageBasisPoints,
                                                        borrowCapacity,
                                                        alchemist.minimumCollateralization());
            console.log("flashLoanAmount: ", flashLoanAmount);
            if(depositAmount + flashLoanAmount > depositCapacity) {
                flashLoanAmount = depositCapacity - depositAmount;
            }
            //denominated in yield
            underlyingDepositMin = _basisPointAdjustment(
                alchemist.convertUnderlyingTokensToYield(yieldToken, depositAmount + flashLoanAmount),
                                                         underlyingSlippageBasisPoints);
            console.log("underlying deposit min (in yield): ", underlyingDepositMin);
            mintAmount = borrowCapacity + (alchemist.convertYieldTokensToUnderlying(yieldToken, underlyingDepositMin)
                                           * FIXED_POINT_SCALAR / alchemist.minimumCollateralization());
            console.log("mint amount:", mintAmount);
            debtTradeMin = _basisPointAdjustment(mintAmount, debtSlippageBasisPoints);
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
    function getWithdrawUnderlyingParameters(uint shares,
                                             uint32 underlyingSlippageBasisPoints,
                                             uint32 debtSlippageBasisPoints) public view override
    returns(uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) {
        uint freeShares = getFreeWithdrawCapacity(msg.sender);
        if(shares <= freeShares) {
            console.log("simple withdraw");
            minUnderlyingOut = _basisPointAdjustment(shares, underlyingSlippageBasisPoints);
        } else {
            uint remainingShares = shares - freeShares;
            uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);

            flashLoanAmount = alchemist.convertSharesToUnderlyingTokens(yieldToken, remainingShares)
                              * 1e36 / (alchemist.minimumCollateralization() * debtTradeLoss);
            burnAmount = _basisPointAdjustment(flashLoanAmount, debtSlippageBasisPoints);
            debtTradeMin = burnAmount;
            minUnderlyingOut = _basisPointAdjustment(flashLoanAmount - burnAmount, underlyingSlippageBasisPoints);
        }
    }

    /// @dev Fills up as much vault capacity as possible using leverage.
    ///
    /// This method is convenient and unlikely to revert but is vulnerable to sandwich attacks.
    /// @param depositAmount Max amount of underlying token to use as the base deposit
    /// @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token. Must include basis points for peg deviations.
    /// @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token. Does not account for debt peg deviations.
    ///
    function leverageAtomic(uint depositAmount,
                            uint32 underlyingSlippageBasisPoints,
                            uint32 debtSlippageBasisPoints) external override {
        (uint clampedDeposit,
         uint flashLoanAmount,
         uint underlyingDepositMin,
         uint mintAmount,
         uint debtTradeMin) = getLeverageParameters(depositAmount,
                                                    underlyingSlippageBasisPoints,
                                                    debtSlippageBasisPoints);
        leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin);
    }

    function leverage(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin) public override {
        require(clampedDeposit > 0, "Vault is full");
        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), clampedDeposit);

        if(flashLoanAmount == 0) {
            console.log("Basic deposit");
            _depositUnderlying(clampedDeposit, underlyingDepositMin, msg.sender);
        } else {
            (IERC20[] memory tokens, uint[] memory amounts) = _getFlashLoanParameters(flashLoanAmount);
            bytes memory data = abi.encode(msg.sender,
                                           true,
                                           clampedDeposit,
                                           flashLoanAmount,
                                           underlyingDepositMin,
                                           mintAmount,
                                           debtTradeMin);
            vault.flashLoan(this, tokens, amounts, data);
        }
        //the dust should get transmitted back to msg.sender but it might not be worth the gas...
    }

    function _getFlashLoanParameters(uint flashLoanAmount) internal view returns (IERC20[] memory tokens,
                                                                                  uint[] memory amounts) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(underlyingToken);
        amounts = new uint[](1);
        amounts[0] = flashLoanAmount;
    }

    // so its really tricky having to have a contract receive the same callback signature with two different callback flows...
    // as luck would have it deposit and withdraw have the same number of parameters on their callback
    function receiveFlashLoan(IERC20[] memory,
                              uint256[] memory,
                              uint256[] memory,
                              bytes memory userData) external override {
        //We'd really like to find a way to flashloan while retaining msg.sender.
        //so that we don't need a mint allowance on alchemix to the leverager
        require(msg.sender == address(vault));
        (address depositor,
         bool depositFlag,
         uint param1,
         uint param2,
         uint param3,
         uint param4,
         uint param5) = abi.decode(userData, (address, bool, uint, uint, uint, uint, uint));
        if(depositFlag) {
            _flashLoanDeposit(depositor, param1, param2, param3, param4, param5);
        } else {
            _flashLoanWithdraw(depositor, param1, param2, param3, param4, param5);
        }
    }

    function _flashLoanDeposit(address depositor,
                               uint clampedDeposit,
                               uint flashLoanAmount,
                               uint underlyingDepositMin,
                               uint mintAmount,
                               uint debtTradeMin) internal {
        uint totalDeposit = clampedDeposit + flashLoanAmount;
        _depositUnderlying(totalDeposit, underlyingDepositMin, depositor);
        _mintDebtTokens(mintAmount, depositor);
        _swapDebtTokens(mintAmount, debtTradeMin);
        _repayFlashLoan(flashLoanAmount);
    }

    function _calculateFlashLoanAmount(uint depositAmount,
                                       uint32 underlyingSlippageBasisPoints,
                                       uint32 debtSlippageBasisPoints,
                                       uint borrowCapacity,
                                       uint minimumCollateralization) internal pure returns (uint flashLoanAmount) {
        //normalizeDebt is returning 1:1 despite the alETH peg being .97
        //We would need to get the actual price per token from our curve factory.
        //I think we can just bundle the peg deviation with the slippage into debtSlippageBasisPoints for now.
        uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);
        uint totalTradeLoss = _basisPointAdjustment(debtTradeLoss, underlyingSlippageBasisPoints);
        flashLoanAmount = ((totalTradeLoss * depositAmount)
                           + (minimumCollateralization * debtTradeLoss * borrowCapacity / 1e18))
                           / (minimumCollateralization - totalTradeLoss);
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
    }

    //amount denominated in debt tokens
    function _swapDebtTokens(uint amount, uint minAmountOut) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapTo = underlyingToken == weth ? curveEth : underlyingToken;
        
        (address pool, uint256 amountOut) = curveFactory.get_best_rate(debtToken, swapTo, amount);
        require(amountOut >= minAmountOut, "Swap exceeds max acceptable loss");
        IERC20(debtToken).approve(dex, amount);
        uint amountReceived = curveFactory.exchange(pool, debtToken, swapTo, amount, minAmountOut, address(this));
        console.log("Swapped: ", amount, amountReceived);
        emit Swap(debtToken, underlyingToken, amount, amountReceived);
    }

    function _repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
        console.log("Repaid: ", amount);
    }

    function _basisPointAdjustment(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000 - slippageBasisPoints) / 10000;
    }

    function _basisPointAdjustmentUp(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000 + slippageBasisPoints) / 10000;
    }

    // This method is convenient and unlikely to revert but is vulnerable to sandwich attacks.
    function withdrawUnderlyingAtomic(uint shares,
                                      uint32 underlyingSlippageBasisPoints,
                                      uint32 debtSlippageBasisPoints) external override {
        (uint flashLoanAmount,
         uint burnAmount,
         uint debtTradeMin,
         uint minUnderlyingOut) = getWithdrawUnderlyingParameters(shares,
                                                                  underlyingSlippageBasisPoints,
                                                                  debtSlippageBasisPoints);
        withdrawUnderlying(shares, flashLoanAmount, burnAmount, debtTradeMin, minUnderlyingOut);
    }

    function withdrawUnderlying(uint shares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut) public override {
        require(shares > 0, "must include shares to withdraw");
        require(shares <= getTotalWithdrawCapacity(msg.sender), "shares exceeds capacity");
        if(burnAmount == 0) {
            alchemist.withdrawUnderlyingFrom(msg.sender, yieldToken, shares, msg.sender, minUnderlyingOut);
        } else {
            (IERC20[] memory tokens, uint[] memory amounts) = _getFlashLoanParameters(flashLoanAmount);
            bytes memory data = abi.encode(msg.sender,
                                           false,
                                           shares,
                                           flashLoanAmount,
                                           burnAmount,
                                           debtTradeMin,
                                           minUnderlyingOut);

            vault.flashLoan(this, tokens, amounts, data);
        }
    }

    function _flashLoanWithdraw(address depositor,
                                uint shares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut) internal {
        _swapToDebtTokens(flashLoanAmount, debtTradeMin);
        _burnDebt(burnAmount, depositor);
        _withdrawUnderlying(depositor, shares, minUnderlyingOut);
        _repayFlashLoan(flashLoanAmount);
        IERC20 token = IERC20(underlyingToken);
        TransferHelper.safeTransfer(underlyingToken, depositor, token.balanceOf(address(this)));
    }

    function _swapToDebtTokens(uint amount, uint minAmountOut) internal {
        ICurveFactory curveFactory = ICurveFactory(dex);
        address swapFrom = underlyingToken;
        if(underlyingToken == weth) {
            swapFrom = curveEth;
            IWETH(weth).withdraw(amount);
        }

        (address pool, uint256 amountOut) = curveFactory.get_best_rate(swapFrom, debtToken, amount);
        require(amountOut >= minAmountOut, "Swap exceeds max acceptable loss");
        uint amountReceived = curveFactory.exchange{value:amount}(pool, swapFrom, debtToken, amount, minAmountOut);
        console.log("Swapped: ", amount, amountReceived);
        emit Swap(underlyingToken, debtToken, amount, amountReceived);
    }

    function _burnDebt(uint burnAmount, address depositor) internal {
        IERC20 token = IERC20(debtToken);
        token.approve(debtSource, burnAmount);
        alchemist.burn(burnAmount, depositor);
        console.log("Burned: ", burnAmount, depositor);
        emit Burn(debtToken, burnAmount);
    }

    function _withdrawUnderlying(address depositor, uint shares, uint minUnderlyingOut) internal {
        uint underlying = alchemist.withdrawUnderlyingFrom(depositor,
                                                           yieldToken,
                                                           shares,
                                                           address(this),
                                                           minUnderlyingOut);

        console.log("WithdrawUnderlying: ", shares, underlying);
        emit WithdrawUnderlying(underlyingToken, shares, underlying);
    }

    receive() external payable {
        if(msg.sender!=weth) {
            IWETH(weth).deposit{value: msg.value}();
            console.log("WETH deposited: ", msg.value);
        } else {
            console.log("ETH unwrapped from wETH: ", msg.value);
        }
    }
}