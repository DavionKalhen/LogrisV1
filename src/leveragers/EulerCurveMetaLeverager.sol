pragma solidity 0.8.19;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../interfaces/alchemist/IAlchemistV2.sol";
import "../interfaces/euler/IFlashLoan.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
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

    //this needs to be rewritten for underlying
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

    //this needs to be rewritten for underlying
    function getRedeemableBalance(address _depositor) external view returns(uint amount) {
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        (uint256 shares,) = alchemist.positions(_depositor, yieldToken);
        uint256 depositedYieldTokens = alchemist.convertSharesToYieldTokens(yieldToken, shares);

        (int256 debtTokens,) = alchemist.accounts(_depositor);
        uint256 debtYieldTokens;
        if(debtTokens>0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(debtTokens));
            debtYieldTokens = alchemist.convertUnderlyingTokensToYield(yieldToken, underlyingDebt);
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(underlyingToken, uint(-1*debtTokens));
            debtYieldTokens = alchemist.convertUnderlyingTokensToYield(yieldToken, underlyingCredit);
        }

        return depositedYieldTokens - debtYieldTokens;
    }

    function withdrawUnderlying(uint amount) external {
        require(amount>0);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //need to calculate shares
        uint256 shares = 0;
        alchemist.withdrawUnderlying(yieldToken, shares, msg.sender, amount);
        require(false, "Not yet implemented");
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
    function leverage(uint allowedSlippageBasisPoints, uint depositPoolAmount) external returns(uint depositAmount, uint debtAmount) {
        require(allowedSlippageBasisPoints>0);
        //we may actually just be able to leverage to fill up existing credit without more deposits
        require(depositPoolAmount>0);
        IAlchemistV2 alchemist = IAlchemistV2(debtSource);
        //need to calculate minimum amount out
        uint minimumAmountOut = 0;
        depositAmount=alchemist.depositUnderlying(yieldToken, depositPoolAmount, msg.sender, minimumAmountOut);
        debtAmount=0;
        require(false, "Not yet implemented");
    }

    function onFlashLoan(bytes memory data) external {
        require(false, "Not yet implemented");
    }
}