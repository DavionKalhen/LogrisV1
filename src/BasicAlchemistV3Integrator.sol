// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./base/AlchemistV3Base.sol";

/**
 * @title BasicAlchemistV3Integrator
 * @notice Basic single-user contract for interacting with Alchemist v3
 * @dev This contract manages a single position in Alchemist v3 for one user
 */
contract BasicAlchemistV3Integrator is AlchemistV3Base {
    
    // Position tracking
    uint256 public positionId;
    bool public positionCreated;
    
    // Additional events specific to this contract
    event PositionCreated(uint256 indexed positionId);
    event YieldTokensDeposited(uint256 amount);
    event DebtMinted(uint256 amount);
    event DebtRepaid(uint256 amount);
    event CollateralWithdrawn(uint256 amount);
    
    // Errors specific to this contract
    error PositionNotCreated();
    error PositionAlreadyCreated();

    /**
     * @notice Constructor
     * @param _alchemist Address of the AlchemistV3 contract
     * @param _positionNFT Address of the AlchemistV3Position contract (not used, derived from alchemist)
     * @param _owner Owner of this integrator contract
     */
    constructor(
        address _alchemist,
        address _positionNFT, // Keep for compatibility but not used
        address _owner
    ) AlchemistV3Base(_alchemist, _owner) {
        // positionNFT is automatically set in base contract
    }

    /**
     * @notice Create a new position in Alchemist v3 with initial yield token deposit
     * @param yieldTokenAmount Amount of yield tokens to deposit
     */
    function createPosition(uint256 yieldTokenAmount) external onlyOwner {
        if (positionCreated) revert PositionAlreadyCreated();
        
        // Transfer yield tokens from user to this contract
        _transferYieldTokensFrom(msg.sender, yieldTokenAmount);
        
        // Create position using base contract functionality
        positionId = _createPosition(address(this), yieldTokenAmount);
        positionCreated = true;
        
        emit PositionCreated(positionId);
        emit YieldTokensDeposited(yieldTokenAmount);
    }

    /**
     * @notice Add more yield tokens to existing position
     * @param yieldTokenAmount Amount of yield tokens to deposit
     */
    function addCollateral(uint256 yieldTokenAmount) external onlyOwner {
        if (!positionCreated) revert PositionNotCreated();
        
        // Transfer yield tokens from user to this contract
        _transferYieldTokensFrom(msg.sender, yieldTokenAmount);
        
        // Deposit to existing position using base contract functionality
        _depositToPosition(positionId, yieldTokenAmount, address(this));
        
        emit YieldTokensDeposited(yieldTokenAmount);
    }

    /**
     * @notice Mint debt tokens against the position
     * @param debtAmount Amount of debt tokens to mint
     */
    function borrowAgainstPosition(uint256 debtAmount) external onlyOwner {
        if (!positionCreated) revert PositionNotCreated();
        
        // Mint debt tokens using base contract functionality
        _mintDebt(positionId, debtAmount, owner());
        
        emit DebtMinted(debtAmount);
    }

    /**
     * @notice Repay debt using yield tokens
     * @param yieldTokenAmount Amount of yield tokens to use for repayment
     */
    function repayDebt(uint256 yieldTokenAmount) external onlyOwner {
        if (!positionCreated) revert PositionNotCreated();
        
        // Transfer yield tokens from user to this contract
        _transferYieldTokensFrom(msg.sender, yieldTokenAmount);
        
        // Repay debt using base contract functionality
        uint256 actualRepaid = _repayDebt(positionId, yieldTokenAmount);
        
        emit DebtRepaid(actualRepaid);
    }

    /**
     * @notice Withdraw collateral from the position
     * @param amount Amount of yield tokens to withdraw
     */
    function withdrawCollateral(uint256 amount) external onlyOwner {
        if (!positionCreated) revert PositionNotCreated();
        
        // Withdraw collateral using base contract functionality
        uint256 actualWithdrawn = _withdrawCollateral(positionId, amount, owner());
        
        emit CollateralWithdrawn(actualWithdrawn);
    }

    /**
     * @notice Get position information
     * @return collateral Amount of collateral in the position
     * @return debt Amount of debt in the position
     * @return earmarked Amount of earmarked debt
     */
    function getPositionInfo() external view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        if (!positionCreated) {
            return (0, 0, 0);
        }
        return _getPositionInfo(positionId);
    }

    /**
     * @notice Get maximum borrowable amount
     * @return maxDebt Maximum debt that can be borrowed
     */
    function getMaxBorrowable() external view returns (uint256 maxDebt) {
        if (!positionCreated) {
            return 0;
        }
        return _getMaxBorrowable(positionId);
    }

    /**
     * @notice Get position health information
     * @return currentCollateral Current collateral value
     * @return currentDebt Current debt value
     * @return collateralizationRatio Current collateralization ratio (collateral/debt)
     * @return isHealthy Whether the position is healthy
     */
    function getPositionHealth() external view returns (
        uint256 currentCollateral,
        uint256 currentDebt,
        uint256 collateralizationRatio,
        bool isHealthy
    ) {
        if (!positionCreated) {
            return (0, 0, type(uint256).max, true);
        }
        
        return _getPositionHealth(positionId);
    }

    /**
     * @notice Emergency withdraw - withdraw all possible collateral
     * @dev Only callable by owner in case of emergency
     */
    function emergencyWithdraw() external onlyOwner {
        if (!positionCreated) revert PositionNotCreated();
        
        (uint256 collateral, uint256 debt,) = _getPositionInfo(positionId);
        
        if (debt > 0) {
            // If there's debt, we can only withdraw excess collateral
            uint256 minCollateralization = this.getMinimumCollateralization();
            uint256 requiredCollateral = (debt * minCollateralization) / 1e18;
            
            if (collateral > requiredCollateral) {
                uint256 withdrawable = collateral - requiredCollateral;
                uint256 actualWithdrawn = _withdrawCollateral(positionId, withdrawable, owner());
                emit CollateralWithdrawn(actualWithdrawn);
            }
        } else {
            // If no debt, withdraw all collateral
            if (collateral > 0) {
                uint256 actualWithdrawn = _withdrawCollateral(positionId, collateral, owner());
                emit CollateralWithdrawn(actualWithdrawn);
            }
        }
    }
} 