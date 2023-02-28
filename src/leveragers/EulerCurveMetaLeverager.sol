pragma solidity 0.8.19;

import "../interfaces/ILeverager.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../interfaces/alchemist/IAlchemistV2.sol";
import "../interfaces/euler/IFlashLoan.sol";
import "../interfaces/euler/DToken.sol";
import "../interfaces/euler/Markets.sol";
import {IStableMetaPool} from "../interfaces/curve/IStableMetaPool.sol";
import {EulerCurveMetaLeveragerStorage} from "./EulerCurveMetaLeveragerStorage.sol";

contract EulerCurveMetaLeverager is ILeverager, Ownable {
    constructor(address _yieldToken, address _underlyingToken, address _debtToken, address _flashLoan, address _debtSource, address _dexPool, int128 _debtTokenCurveIndex, int128 _underlyingTokenCurveIndex) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        s.yieldToken = _yieldToken;
        s.underlyingToken = _underlyingToken;
        s.debtToken = _debtToken;
        s.flashLoan = _flashLoan;
        s.debtSource = _debtSource;
        s.dexPool = _dexPool;
        s.debtTokenCurveIndex = _debtTokenCurveIndex;
        s.underlyingTokenCurveIndex = _underlyingTokenCurveIndex;
    }

    function getYieldToken() external view returns(address yieldToken) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.yieldToken;
    }

    function getUnderlyingToken() external view returns(address underlyingToken) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.underlyingToken;
    }

    function getDebtToken() external view returns(address debtToken) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.debtToken;
    }

    function getFlashLoan() external view returns (address) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.flashLoan;
    }

    function getDebtSource() external view returns (address) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.debtSource;
    }

    function getDexPool() external view returns (address) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        return s.dexPool;
    }

    //this needs to be rewritten for underlying
    function getDepositedBalance(address _depositor) external view returns(uint amount) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        //last accrued weight appears to be unrealized credit denominated in debt tokens
        (uint256 shares,) = alchemist.positions(_depositor, s.yieldToken);
        uint256 yieldTokens = alchemist.convertSharesToYieldTokens(s.yieldToken, shares);
        return yieldTokens;
    }

    function getDebtBalance(address _depositor) external view returns(int256 amount) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        (int256 debt,) = alchemist.accounts(_depositor);
        return debt;
    }

    //this needs to be rewritten for underlying
    function getRedeemableBalance(address _depositor) external view returns(uint amount) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        (uint256 shares,) = alchemist.positions(_depositor, s.yieldToken);
        uint256 depositedYieldTokens = alchemist.convertSharesToYieldTokens(s.yieldToken, shares);

        (int256 debtTokens,) = alchemist.accounts(_depositor);
        uint256 debtYieldTokens;
        if(debtTokens>0) {
            uint256 underlyingDebt = alchemist.normalizeDebtTokensToUnderlying(s.underlyingToken, uint(debtTokens));
            debtYieldTokens = alchemist.convertUnderlyingTokensToYield(s.yieldToken, underlyingDebt);
        } else {
            uint256 underlyingCredit = alchemist.normalizeDebtTokensToUnderlying(s.underlyingToken, uint(-1*debtTokens));
            debtYieldTokens = alchemist.convertUnderlyingTokensToYield(s.yieldToken, underlyingCredit);
        }

        return depositedYieldTokens - debtYieldTokens;
    }

    function withdrawUnderlying(uint amount) external {
        require(amount>0);
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        //need to calculate shares
        uint256 shares = 0;
        alchemist.withdrawUnderlying(s.yieldToken, shares, msg.sender, amount);
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
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        //need to calculate minimum amount out
        uint minimumAmountOut = 0;
        depositAmount=alchemist.depositUnderlying(s.yieldToken, depositPoolAmount, msg.sender, minimumAmountOut);
        debtAmount=0;
        require(false, "Not yet implemented");
    }

    function onFlashLoan(bytes memory data) external {
        require(false, "Not yet implemented");
    }
}