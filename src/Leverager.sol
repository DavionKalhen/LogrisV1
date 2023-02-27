// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "./interfaces/alchemist/IAlchemistV2.sol";
import "./interfaces/alchemist/Sets.sol";
import "./interfaces/alchemist/ITokenAdapter.sol";
import "forge-std/console.sol";


contract Leverager is Ownable {
    uint256 public heldAssets;
    uint256 public borrowedAssets;
    IAlchemistV2 public alchemist;
    address underlyingToken;

    struct Account {
        // A signed value which represents the current amount of debt or credit that the account has accrued.
        // Positive values indicate debt, negative values indicate credit.
        int256 debt;
        // The share balances for each yield token.
        mapping(address => uint256) balances;
        // The last values recorded for accrued weights for each yield token.
        mapping(address => uint256) lastAccruedWeights;
        // The set of yield tokens that the account has deposited into the system.
        Sets.AddressSet depositedTokens;
        // The allowances for mints.
        mapping(address => uint256) mintAllowances;
        // The allowances for withdrawals.
        mapping(address => mapping(address => uint256)) withdrawAllowances;
    }

    constructor(address underlyingToken_) {
        alchemist = IAlchemistV2(0xde399d26ed46B7b509561f1B9B5Ad6cc1EBC7261);
        underlyingToken = underlyingToken_;
    }

    function addAssets(uint _assets) external onlyOwner {
        heldAssets += _assets;
    }

    function validateDebtRatio() public view returns (bool) {
        (int256 unrealizedDebt, address [] memory values) = alchemist.accounts(address(this));
        uint256 _totalValue = totalValue(values);
        if(_totalValue == 0) {
            return false;
        }
        uint256 debtRatio = uint256(unrealizedDebt) / _totalValue;
        uint256 minimumCollateralization = alchemist.minimumCollateralization();
        return debtRatio < minimumCollateralization;
    }

    function leverage() external onlyOwner {
        require(heldAssets > 0, "No assets to leverage");
        //deposit as much as we can.
        //alchemist.depositUnderlying( yieldToken, heldAssets, address(this), heldAssets);
        //Check our debt ratio
         if(validateDebtRatio()) {
             //If we are undercollateralized, mint more yield tokens
             alchemist.mint(heldAssets, address(this));
             console.log("Minting more yield tokens");
         }
         else console.log("Nothing to mint");

    }
    function totalValue(address [] memory values) internal view returns (uint256 totalValue_) {

        for (uint256 i = 0; i < values.length; i++) {
            address yieldToken_             = values[i];
            IAlchemistV2.YieldTokenParams memory yieldTokenParams = alchemist.getYieldTokenParameters(yieldToken_);
            address underlyingToken_        = yieldTokenParams.underlyingToken;
            (uint256 shares, )             = alchemist.positions(address(this), yieldToken_);
            uint256 amountUnderlyingTokens = _convertSharesToUnderlyingTokens(yieldTokenParams, shares);

            totalValue_ += _normalizeUnderlyingTokensToDebt(underlyingToken_, amountUnderlyingTokens);
        }
    }
    function _convertSharesToUnderlyingTokens(IAlchemistV2.YieldTokenParams memory yieldTokenParams, uint256 shares) internal view returns (uint256) {
        uint256 amountYieldTokens = _convertSharesToYieldTokens(yieldTokenParams, shares);
        return _convertYieldTokensToUnderlying(yieldTokenParams, amountYieldTokens);
    }

    function _convertYieldTokensToUnderlying( IAlchemistV2.YieldTokenParams memory yieldTokenParams , uint256 amount) internal view returns (uint256) {
        ITokenAdapter adapter = ITokenAdapter(yieldTokenParams.adapter);
        return amount * adapter.price() / 10**yieldTokenParams.decimals;
    }

    function _convertSharesToYieldTokens(IAlchemistV2.YieldTokenParams memory  yieldTokenParams, uint256 shares) internal view returns (uint256) {
        uint256 totalShares = yieldTokenParams.totalShares;
        if (totalShares == 0) {
          return shares;
        }
        return (shares * _calculateUnrealizedActiveBalance(yieldTokenParams)) / totalShares;
    }  

    function _calculateUnrealizedActiveBalance(IAlchemistV2.YieldTokenParams memory yieldTokenParams) internal view returns (uint256) {
        uint256 activeBalance = yieldTokenParams.activeBalance;
        if (activeBalance == 0) {
          return activeBalance;
        }

        uint256 currentValue = _convertYieldTokensToUnderlying(yieldTokenParams, activeBalance);
        uint256 expectedValue = yieldTokenParams.expectedValue;
        if (currentValue <= expectedValue) {
          return activeBalance;
        }

        uint256 harvestable = _convertUnderlyingTokensToYield(yieldTokenParams, currentValue - expectedValue);
        if (harvestable == 0) {
          return activeBalance;
        }

        return activeBalance - harvestable;
    }       
    function _normalizeUnderlyingTokensToDebt(address underlyingToken_, uint256 amount) internal view returns (uint256) {
        IAlchemistV2.UnderlyingTokenParams memory underlyingTokenParams = alchemist.getUnderlyingTokenParameters(underlyingToken_);
        return amount * underlyingTokenParams.conversionFactor;
    }
    function _convertUnderlyingTokensToYield(IAlchemistV2.YieldTokenParams memory yieldTokenParams, uint256 amount) internal view returns (uint256) {
        ITokenAdapter adapter = ITokenAdapter(yieldTokenParams.adapter);
        return amount * 10**yieldTokenParams.decimals / adapter.price();
    }         
}