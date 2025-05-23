// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../interfaces/wETH/IWETH.sol";
import "../interfaces/IDebtTokenAdapter.sol";
import "../interfaces/alchemist/ITokenAdapter.sol";
import "../interfaces/uniswap/TransferHelper.sol";

abstract contract Leverager is ILeverager, Ownable {
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    IDebtTokenAdapter public debtAdapter;
    
    
    uint256 constant FIXED_POINT_SCALAR = 1e18;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    constructor(address _yieldToken,
    address _underlyingToken,
    address _debtToken,
    address _debtAdapter)
    Ownable(msg.sender) {
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = _debtToken;
        debtAdapter = IDebtTokenAdapter(_debtAdapter);
    }

    /// @dev this function needs to be implemented in the inheriting contract
    function _leverageWithFlashLoan(uint clampedDeposit, uint flashLoanAmount, uint underlyingDepositMin, uint mintAmount, uint debtTradeMin, bytes memory swapParams) internal virtual;
    /// @dev this function needs to be implemented in the inheriting contract
    function _withdrawUnderlyingWithBurn(uint shares, uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut, bytes memory swapParams) internal virtual;
    /// @dev this function needs to be implemented in the inheriting contract
    function _swapDebtTokens(uint amount, uint minAmountOut, bytes memory swapParams) internal virtual;
    /// @dev this function needs to be implemented in the inheriting contract
    function _swapToDebtTokens(uint amount, uint minAmountOut, bytes memory swapParams) internal virtual;

    /**
        * @notice Return the amount of underlying tokens deposited in this pool by `_depositor`
        * @param _depositor address of depositor
        * @return amount of underlying tokens
     */
    function getDepositedBalance(address _depositor) public view override returns(uint amount) {
        //last accrued weight appears to be unrealized borrowCapacity denominated in debt tokens
        (uint256 shares,) = debtAdapter.positions(_depositor, yieldToken);
        amount = debtAdapter.convertSharesToUnderlyingTokens(yieldToken, shares);
    }

    /**
        * @notice Return the amount of debt tokens deposited in this pool by `_depositor`
        * @param _depositor address of depositor
        * @return amount of debt tokens
     */
    function getDebtBalance(address _depositor) public view override returns(int256 amount) {
        (amount,) = debtAdapter.accounts(_depositor);
    }

    function abs(int256 x) internal pure returns (uint256) {
        if (x < 0) {
            return uint256(-x);
        }
        return uint256(x);
    }

    /**
        * @notice Return the amount of underlying tokens that can be redeemed by `_depositor`
        * @param _depositor address of depositor
        * @return amount of underlying tokens
     */
    function getRedeemableBalance(address _depositor) public view override returns(uint amount) {
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        uint256 debtOrCredit = debtAdapter.normalizeDebtTokensToUnderlying(underlyingToken, abs(debtBalance));
        // using a conditional here to avoid sign operations on uints
        if(debtBalance < 0) {
            return depositBalance + debtOrCredit;
        } else {
            return depositBalance - debtOrCredit;
        }
    }

    /**
        * @notice Checks the remaining capacity of the debt adapter vault
        * @return amount amount of underlying tokens that can be deposited in the vault
    */
    function getDepositCapacity() public view override returns(uint amount) {
        (uint256 expectedValue, uint256 maximumExpectedValue,,) = debtAdapter.getYieldTokenParameters(yieldToken);
        if(maximumExpectedValue >= expectedValue)
            amount = maximumExpectedValue - expectedValue;
        else
            amount = 0;
    }

    /**
        * @notice Calculates the remaining borrow capacity of the depositor
        * @param _depositor Address of depositor
        * @return amount Amount of underlying tokens that can be borrowed
    */
    function getBorrowCapacity(address _depositor) public view override returns(uint amount) {
        uint256 minimumCollateralization = debtAdapter.minimumCollateralization();//includes 1e18
        uint depositBalance = getDepositedBalance(_depositor);     
        int256 debtBalance = getDebtBalance(_depositor);
        uint256 debtAdjustedBalance = 0;
        uint256 debtOrCredit = debtAdapter.normalizeDebtTokensToUnderlying(underlyingToken, abs(debtBalance));
        uint256 debtOrCreditAdj = debtOrCredit * minimumCollateralization / FIXED_POINT_SCALAR;

        // using a conditional here to avoid sign operations on uints
        if(debtBalance < 0) {
            debtAdjustedBalance = depositBalance + debtOrCreditAdj;
        } else {
            debtAdjustedBalance = depositBalance - debtOrCreditAdj;
        }

        amount = debtAdjustedBalance * FIXED_POINT_SCALAR / minimumCollateralization;
    }

    /**
        * @notice Returns the amount of depositor shares that can be withdrawn from the vault
        * @param _depositor Address of depositor
        * @return shares Amount of adapter shares
    */
    function getTotalWithdrawCapacity(address _depositor) public view override returns (uint shares) {
        (shares,) = debtAdapter.positions(_depositor, yieldToken);
        return shares;
    }

    /**
        * @notice Returns the amount of depositor shares that can be withdrawn from the vault without liquidating debt
        * @param _depositor Address of depositor
        * @return shares Amount of adapter shares
    */
    function getFreeWithdrawCapacity(address _depositor) public view override returns(uint shares) {
        uint256 minimumCollateralization = debtAdapter.minimumCollateralization();//includes 1e18

        (uint256 totalShares,) = debtAdapter.positions(_depositor, yieldToken);
        int256 debtBalance = getDebtBalance(_depositor);
        uint clampedDebt = (debtBalance <= 0) ? 0: uint(debtBalance);
        uint debtShares = debtAdapter.normalizeDebtTokensToUnderlying(underlyingToken, clampedDebt)
                          * minimumCollateralization / FIXED_POINT_SCALAR;

        shares = totalShares - debtShares;
    }

    /**
        * @notice Returns the amount of adapter shares that corresponds to the amount of tokens
        * @param amount Amount of underlying tokens to convert
        * @return shares Amount of adapter shares
    */
    function convertUnderlyingTokensToShares(uint256 amount) external view override returns (uint shares) {
        shares = debtAdapter.convertUnderlyingTokensToShares(yieldToken, amount);
    }

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
                debtAdapter.convertUnderlyingTokensToYield(yieldToken, clampedDeposit),
                underlyingSlippageBasisPoints);
        }
        else {
            clampedDeposit = depositAmount;
            uint borrowCapacity = getBorrowCapacity(msg.sender);
            flashLoanAmount = _calculateFlashLoanAmount(depositAmount,
                                                        underlyingSlippageBasisPoints,
                                                        debtSlippageBasisPoints,
                                                        borrowCapacity,
                                                        debtAdapter.minimumCollateralization());
            if(depositAmount + flashLoanAmount > depositCapacity) {
                flashLoanAmount = depositCapacity - depositAmount;
            }
            //denominated in yield
            underlyingDepositMin = _basisPointAdjustment(
                debtAdapter.convertUnderlyingTokensToYield(yieldToken, depositAmount + flashLoanAmount),
                                                         underlyingSlippageBasisPoints);
            mintAmount = borrowCapacity + (debtAdapter.convertYieldTokensToUnderlying(yieldToken, underlyingDepositMin)
                                           * FIXED_POINT_SCALAR / debtAdapter.minimumCollateralization());
            debtTradeMin = _basisPointAdjustment(mintAmount, debtSlippageBasisPoints);
        }
    }

    /**
        * @notice Deposit underlying tokens in debt adapter
        * @param clampedDeposit Amount of underlying tokens to deposit
        * @param flashLoanAmount Amount of underlying tokens to borrow
        * @param underlyingDepositMin Minimum amount of yield tokens to receive
        * @param mintAmount Amount of debt tokens to mint
        * @param debtTradeMin Minimum amount of debt tokens to receive to protect from slippage
        * @param swapParams Parameters for the swap (curve or else)
    */
    function leverage(uint clampedDeposit,
                      uint flashLoanAmount,
                      uint underlyingDepositMin,
                      uint mintAmount,
                      uint debtTradeMin,
                      bytes memory swapParams) public {
        require(clampedDeposit > 0, "Vault is full");
        TransferHelper.safeTransferFrom(underlyingToken, msg.sender, address(this), clampedDeposit);

        if(flashLoanAmount == 0) {
            _depositUnderlying(clampedDeposit, underlyingDepositMin, msg.sender);
        } else {
            _leverageWithFlashLoan(clampedDeposit,
                                   flashLoanAmount,
                                   underlyingDepositMin,
                                   mintAmount,
                                   debtTradeMin,
                                   swapParams);
        }
        //the dust should get transmitted back to msg.sender but it might not be worth the gas...
    }

    /**
        * @notice Deposit underlying tokens in debt adapter on behalf of the depositor
        * @param depositor Address of depositor
        * @param clampedDeposit Amount of underlying tokens to deposit
        * @param flashLoanAmount Amount of underlying tokens to borrow
        * @param underlyingDepositMin Minimum amount of yield tokens to receive
        * @param mintAmount Amount of debt tokens to mint
        * @param debtTradeMin Minimum amount of debt tokens to receive to protect from slippage
    */
    function _flashLoanDeposit(address depositor,
                               uint clampedDeposit,
                               uint flashLoanAmount,
                               uint underlyingDepositMin,
                               uint mintAmount,
                               uint debtTradeMin,
                               bytes memory swapParams) internal {
        uint totalDeposit = clampedDeposit + flashLoanAmount;
        _depositUnderlying(totalDeposit, underlyingDepositMin, depositor);
        _mintDebtTokens(mintAmount, depositor);
        _swapDebtTokens(mintAmount, debtTradeMin, swapParams);
        _repayFlashLoan(flashLoanAmount);
    }

    /**
        * @notice need help understanding this
    */
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

    /**
        * @notice Deposit underlying tokens in debt adapter
        * @param amount Amount of underlying tokens to deposit
        * @param minAmountOut Minimum amount of yield tokens to receive
        * @param _sender Address of depositor
    */
    function _depositUnderlying(uint amount, uint minAmountOut, address _sender) internal {
        IERC20(underlyingToken).approve(address(debtAdapter), amount);
        uint shares = debtAdapter.depositUnderlying(yieldToken, amount, _sender, minAmountOut);
        emit DepositUnderlying(underlyingToken, amount, debtAdapter.convertSharesToUnderlyingTokens(yieldToken, shares));
    }

    /**
        * @notice Mint debt tokens in adapter
        * @param mintAmount Amount of debt tokens to mint
        * @param _sender Address of depositor
    */
    function _mintDebtTokens(uint mintAmount, address _sender) internal {
        //this needs to be accountd for in calculate flash loan
        // (uint maxMintable, ,) = debtAdapter.getMintLimitInfo();
        // if (amount > maxMintable) {
        //     //mint as much as possible.
        //     amount = maxMintable;
        // }
        //Mint Debt Tokens
        debtAdapter.mintFrom(_sender, mintAmount, address(this));
        emit Mint(yieldToken, mintAmount);
    }
    
    /**
        * @notice Repay flash loan
        * @param amount Amount of underlying tokens to repay
    */
    function _repayFlashLoan(uint amount) internal {
        TransferHelper.safeTransfer(underlyingToken, msg.sender, amount);
    }

    /**
        * @notice Applies slippage points to a token amount by reducing it
        * @param amountIn Amount of tokens to adjust
        * @param slippageBasisPoints Slippage tolerance expressed in 1/100 of a percent
    */
    function _basisPointAdjustment(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000 - slippageBasisPoints) / 10000;
    }

    /**
        * @notice Applies slippage points to a token amount by augmenting it
        * @param amountIn Amount of tokens to adjust
        * @param slippageBasisPoints Slippage tolerance expressed in 1/100 of a percent
    */
    function _basisPointAdjustmentUp(uint256 amountIn, uint32 slippageBasisPoints) internal pure returns(uint256) {
        return amountIn * (10000 + slippageBasisPoints) / 10000;
    }

    /**
        * @notice Withdraw underlying tokens from adapter
        * @dev This method is convenient and unlikely to revert but is vulnerable to sandwich attacks.
        * @param shares Amount of shares to withdraw
        * @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token. Must include basis points for peg deviations.
        * @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token
    */
    function withdrawUnderlyingAtomic(uint shares,
                                      uint32 underlyingSlippageBasisPoints,
                                      uint32 debtSlippageBasisPoints,
                                      bytes memory swapParams) external override {
        (uint flashLoanAmount,
         uint burnAmount,
         uint debtTradeMin,
         uint minUnderlyingOut) = getWithdrawUnderlyingParameters(shares,
                                                                  underlyingSlippageBasisPoints,
                                                                  debtSlippageBasisPoints);
        withdrawUnderlying(shares, flashLoanAmount, burnAmount, debtTradeMin, minUnderlyingOut, swapParams);
    }

    /**
        * @notice Withdraw underlying tokens from debt adapter on behalf of the depositor
        * @param depositor Address of depositor
        * @param shares Amount of shares to withdraw
        * @param flashLoanAmount Amount of underlying tokens to borrow
    */
    function _flashLoanWithdraw(address depositor,
                                uint shares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut,
                                bytes memory swapParams) internal {
        _swapToDebtTokens(flashLoanAmount, debtTradeMin, swapParams);
        _burnDebt(burnAmount, depositor);
        _withdrawUnderlying(depositor, shares, minUnderlyingOut);
        _repayFlashLoan(flashLoanAmount);
        IERC20 token = IERC20(underlyingToken);
        TransferHelper.safeTransfer(underlyingToken, depositor, token.balanceOf(address(this)));
    }

    /**
        * @notice Burn debt tokens in adapter and credit the depositor
        * @param burnAmount Amount of debt tokens to burn
        * @param depositor Address of depositor
    */
    function _burnDebt(uint burnAmount, address depositor) internal {
        IERC20 token = IERC20(debtToken);
        token.approve(address(debtAdapter), burnAmount);
        debtAdapter.burn(burnAmount, depositor);
        emit Burn(debtToken, burnAmount);
    }

    /**
        * @notice Withdraw underlying tokens from adapter on behalf of the depositor
        * @param depositor Address of depositor
        * @param shares Amount of shares to withdraw
        * @param minUnderlyingOut Minimum amount of underlying tokens to receive to protect from slippage
    */
    function _withdrawUnderlying(address depositor, uint shares, uint minUnderlyingOut) internal {
        uint underlying = debtAdapter.withdrawUnderlyingFrom(depositor,
                                                           yieldToken,
                                                           shares,
                                                           address(this),
                                                           minUnderlyingOut);

        emit WithdrawUnderlying(underlyingToken, shares, underlying);
    }

    /**
        * @notice need help understanding this
    */
    function getWithdrawUnderlyingParameters(uint shares,
                                             uint32 underlyingSlippageBasisPoints,
                                             uint32 debtSlippageBasisPoints) public view override
    returns(uint flashLoanAmount, uint burnAmount, uint debtTradeMin, uint minUnderlyingOut) {
        uint freeShares = getFreeWithdrawCapacity(msg.sender);
        if(shares <= freeShares) {
            minUnderlyingOut = _basisPointAdjustment(shares, underlyingSlippageBasisPoints);
        } else {
            uint remainingShares = shares - freeShares;
            uint debtTradeLoss =  _basisPointAdjustment(1 ether, debtSlippageBasisPoints);

            flashLoanAmount = debtAdapter.convertSharesToUnderlyingTokens(yieldToken, remainingShares)
                              * 1e36 / (debtAdapter.minimumCollateralization() * debtTradeLoss);
            burnAmount = _basisPointAdjustment(flashLoanAmount, debtSlippageBasisPoints);
            debtTradeMin = burnAmount;
            minUnderlyingOut = _basisPointAdjustment(flashLoanAmount - burnAmount, underlyingSlippageBasisPoints);
        }
    }

    /**
        * @notice Withdraw underlying tokens from adapter
        * @param shares Amount of shares to withdraw
        * @param flashLoanAmount Amount of underlying tokens to borrow
        * @param burnAmount Amount of debt tokens to burn
        * @param debtTradeMin Minimum amount of debt tokens to receive to protect from slippage
        * @param minUnderlyingOut Minimum amount of underlying tokens to receive to protect from slippage
    */
    function withdrawUnderlying(uint shares,
                                uint flashLoanAmount,
                                uint burnAmount,
                                uint debtTradeMin,
                                uint minUnderlyingOut,
                                bytes memory swapParams) public {
        require(shares > 0, "must include shares to withdraw");
        require(shares <= getTotalWithdrawCapacity(msg.sender), "shares exceeds capacity");
        if(burnAmount == 0) {
            debtAdapter.withdrawUnderlyingFrom(msg.sender, yieldToken, shares, msg.sender, minUnderlyingOut);
        } else {
           _withdrawUnderlyingWithBurn(shares, flashLoanAmount, burnAmount, debtTradeMin, minUnderlyingOut, swapParams);
        }
    }

    /**
        * @notice Fills up as much vault capacity as possible using leverage.
        * @dev This method is convenient and unlikely to revert but is vulnerable to sandwich attacks.
        * @param depositAmount Max amount of underlying token to use as the base deposit
        * @param underlyingSlippageBasisPoints Slippage tolerance when trading underlying to yield token.
        * Must include basis points for peg deviations.
        * @param debtSlippageBasisPoints Slippage tolerance when trading debt to underlying token.
        * Does not account for debt peg deviations.
    */
    function leverageAtomic(uint depositAmount,
                            uint32 underlyingSlippageBasisPoints,
                            uint32 debtSlippageBasisPoints,
                            bytes memory swapParams) external override {
        (uint clampedDeposit,
         uint flashLoanAmount,
         uint underlyingDepositMin,
         uint mintAmount,
         uint debtTradeMin) = getLeverageParameters(depositAmount,
                                                    underlyingSlippageBasisPoints,
                                                    debtSlippageBasisPoints);
        leverage(clampedDeposit, flashLoanAmount, underlyingDepositMin, mintAmount, debtTradeMin, swapParams);
    }

    receive() external payable {
        if(msg.sender!=weth) {
            IWETH(weth).deposit{value: msg.value}();
        }
    }
}