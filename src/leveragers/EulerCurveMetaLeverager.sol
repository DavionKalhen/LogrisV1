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

    function getDepositedBalance(address _depositor) external view returns(uint amount) {
        EulerCurveMetaLeveragerStorage.Storage storage s = EulerCurveMetaLeveragerStorage.getStorage();
        IAlchemistV2 alchemist = IAlchemistV2(s.debtSource);
        (uint256 shares, uint256 lastAccruedWeight) = alchemist.positions(_depositor, s.yieldToken);
        uint256 yieldTokens = alchemist.convertSharesToYieldTokens(s.yieldToken, shares);
        return yieldTokens;
    }

    function getDebtBalance(address depositor) external view returns(uint amount) {
        require(false, "Not yet implemented");
    }

    function getRedeemableBalance(address depositor) external view returns(uint amount) {
        require(false, "Not yet implemented");
    }

    function predictWithdraw(uint shares) external view returns(uint amount) {
        require(false, "Not yet implemented");
    }
    
    function withdraw(uint shares) external returns(uint amount) {
        require(false, "Not yet implemented");
    }
    
    function leverage(uint slippageTolerance, uint depositAmount) external {
        require(false, "Not yet implemented");
    }

    function onFlashLoan(bytes memory data) external {
        require(false, "Not yet implemented");
    }
}