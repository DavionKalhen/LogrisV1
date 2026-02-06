// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

/**
 * @title AlchemistV3Base
 * @notice Base contract for AlchemistV3 interactions
 * @dev Contains common functionality for position management and AlchemistV3 operations
 */
abstract contract AlchemistV3Base is Ownable {
    using SafeERC20 for IERC20;

    // Alchemist v3 contracts
    IAlchemistV3 public immutable alchemist;
    IAlchemistV3Position public immutable positionNFT;
    
    // Tokens
    IERC20 public immutable yieldToken;
    IERC20 public immutable debtToken;
    
    // Events
    event PositionCreated(uint256 indexed positionId, address indexed owner);
    event YieldTokensDeposited(uint256 indexed positionId, uint256 amount);
    event DebtMinted(uint256 indexed positionId, uint256 amount, address recipient);
    event DebtRepaid(uint256 indexed positionId, uint256 amount);
    event CollateralWithdrawn(uint256 indexed positionId, uint256 amount, address recipient);
    
    // Errors
    error InvalidAmount();
    error InsufficientBalance();
    error InsufficientCollateral();
    error PositionNotFound();
    error AlchemistCallFailed();

    /**
     * @notice Constructor
     * @param _alchemist Address of the AlchemistV3 contract
     * @param _owner Owner of this contract
     */
    constructor(address _alchemist, address _owner) Ownable(_owner) {
        alchemist = IAlchemistV3(_alchemist);
        positionNFT = IAlchemistV3Position(alchemist.alchemistPositionNFT());
        
        // Get token addresses from alchemist
        yieldToken = IERC20(alchemist.yieldToken());
        debtToken = IERC20(alchemist.debtToken());
    }

    /**
     * @notice Internal function to create a new position
     * @param recipient The recipient of the position NFT
     * @param initialDeposit Initial yield token deposit amount
     * @return positionId The created position ID
     */
    function _createPosition(address recipient, uint256 initialDeposit) internal returns (uint256 positionId) {
        if (initialDeposit == 0) revert InvalidAmount();
        require(!alchemist.depositsPaused(), "Deposits paused");
        uint256 depositCap = alchemist.depositCap();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        uint256 capacity = depositCap >= totalDeposited ? depositCap - totalDeposited : 0;
        require(initialDeposit <= capacity, "Deposit cap exceeded");
        
        // Approve alchemist to spend yield tokens
        yieldToken.approve(address(alchemist), initialDeposit);
        
        // Deposit yield tokens and create position (recipientId = 0 creates new position)
        alchemist.deposit(initialDeposit, recipient, 0);
        
        // Get the position ID that was created
        uint256 balance = positionNFT.balanceOf(recipient);
        positionId = positionNFT.tokenOfOwnerByIndex(recipient, balance - 1);
        
        emit PositionCreated(positionId, recipient);
        emit YieldTokensDeposited(positionId, initialDeposit);
        
        return positionId;
    }

    /**
     * @notice Internal function to deposit yield tokens to existing position
     * @param positionId The position ID to deposit to
     * @param amount Amount of yield tokens to deposit
     * @param recipient The recipient address for the deposit
     */
    function _depositToPosition(uint256 positionId, uint256 amount, address recipient) internal {
        if (amount == 0) revert InvalidAmount();
        require(!alchemist.depositsPaused(), "Deposits paused");
        uint256 depositCap = alchemist.depositCap();
        uint256 totalDeposited = alchemist.getTotalDeposited();
        uint256 capacity = depositCap >= totalDeposited ? depositCap - totalDeposited : 0;
        require(amount <= capacity, "Deposit cap exceeded");
        
        // Approve alchemist to spend yield tokens
        yieldToken.approve(address(alchemist), amount);
        
        // Deposit to existing position
        alchemist.deposit(amount, recipient, positionId);
        
        emit YieldTokensDeposited(positionId, amount);
    }

    /**
     * @notice Internal function to mint debt tokens
     * @param positionId The position ID to mint against
     * @param amount Amount of debt tokens to mint
     * @param recipient The recipient of the debt tokens
     */
    function _mintDebt(uint256 positionId, uint256 amount, address recipient) internal {
        if (amount == 0) revert InvalidAmount();
        require(!alchemist.loansPaused(), "Loans paused");
        
        // Check if we can borrow this amount
        uint256 maxBorrowable = alchemist.getMaxBorrowable(positionId);
        if (amount > maxBorrowable) revert InsufficientCollateral();
        
        // Mint debt tokens
        alchemist.mint(positionId, amount, recipient);
        
        emit DebtMinted(positionId, amount, recipient);
    }

    /**
     * @notice Internal function to repay debt using yield tokens
     * @param positionId The position ID to repay debt for
     * @param yieldTokenAmount Amount of yield tokens to use for repayment
     * @return actualRepaid The actual amount repaid
     */
    function _repayDebt(uint256 positionId, uint256 yieldTokenAmount) internal returns (uint256 actualRepaid) {
        if (yieldTokenAmount == 0) revert InvalidAmount();
        
        // Approve alchemist to spend yield tokens for repayment
        yieldToken.approve(address(alchemist), yieldTokenAmount);
        
        // Repay debt using yield tokens
        actualRepaid = alchemist.repay(yieldTokenAmount, positionId);
        
        emit DebtRepaid(positionId, actualRepaid);
        
        return actualRepaid;
    }

    /**
     * @notice Internal function to withdraw collateral
     * @param positionId The position ID to withdraw from
     * @param amount Amount of yield tokens to withdraw
     * @param recipient The recipient of the withdrawn tokens
     * @return actualWithdrawn The actual amount withdrawn
     */
    function _withdrawCollateral(uint256 positionId, uint256 amount, address recipient) internal returns (uint256 actualWithdrawn) {
        if (amount == 0) revert InvalidAmount();
        
        // Withdraw yield tokens
        actualWithdrawn = alchemist.withdraw(amount, recipient, positionId);
        
        emit CollateralWithdrawn(positionId, actualWithdrawn, recipient);
        
        return actualWithdrawn;
    }

    /**
     * @notice Internal function to approve mint operations
     * @param positionId The position ID to approve for
     * @param spender The address that can mint
     * @param amount The amount that can be minted
     */
    function _approveMint(uint256 positionId, address spender, uint256 amount) internal {
        alchemist.approveMint(positionId, spender, amount);
    }

    /**
     * @notice Internal function to burn debt tokens
     * @param positionId The position ID to burn debt for
     * @param amount The amount of debt tokens to burn
     */
    function _burnDebt(uint256 positionId, uint256 amount) internal {
        if (amount == 0) revert InvalidAmount();
        
        // Approve debt tokens for burning
        debtToken.approve(address(alchemist), amount);
        
        // Burn debt tokens
        alchemist.burn(amount, positionId);
    }

    /**
     * @notice Get position information
     * @param positionId The position ID to query
     * @return collateral Amount of collateral in the position
     * @return debt Amount of debt in the position
     * @return earmarked Amount of earmarked debt
     */
    function _getPositionInfo(uint256 positionId) internal view returns (uint256 collateral, uint256 debt, uint256 earmarked) {
        return alchemist.getCDP(positionId);
    }

    /**
     * @notice Get maximum borrowable amount for a position
     * @param positionId The position ID to query
     * @return maxDebt Maximum debt that can be borrowed
     */
    function _getMaxBorrowable(uint256 positionId) internal view returns (uint256 maxDebt) {
        return alchemist.getMaxBorrowable(positionId);
    }

    /**
     * @notice Get position health information
     * @param positionId The position ID to query
     * @return currentCollateral Current collateral value
     * @return currentDebt Current debt value
     * @return collateralizationRatio Current collateralization ratio (collateral/debt)
     * @return isHealthy Whether the position is healthy
     */
    function _getPositionHealth(uint256 positionId) internal view returns (
        uint256 currentCollateral,
        uint256 currentDebt,
        uint256 collateralizationRatio,
        bool isHealthy
    ) {
        (currentCollateral, currentDebt,) = alchemist.getCDP(positionId);
        
        if (currentDebt == 0) {
            return (currentCollateral, 0, type(uint256).max, true);
        }
        
        // Calculate collateralization ratio (collateral/debt)
        collateralizationRatio = (currentCollateral * 1e18) / currentDebt;
        
        // Check if healthy (above minimum collateralization)
        uint256 minCollateralization = alchemist.minimumCollateralization();
        isHealthy = collateralizationRatio >= minCollateralization;
    }

    /**
     * @notice Internal function to transfer yield tokens from user to this contract
     * @param from The address to transfer from
     * @param amount The amount to transfer
     */
    function _transferYieldTokensFrom(address from, uint256 amount) internal {
        if (yieldToken.balanceOf(from) < amount) revert InsufficientBalance();
        yieldToken.safeTransferFrom(from, address(this), amount);
    }

    /**
     * @notice Internal function to transfer debt tokens from user to this contract
     * @param from The address to transfer from
     * @param amount The amount to transfer
     */
    function _transferDebtTokensFrom(address from, uint256 amount) internal {
        if (debtToken.balanceOf(from) < amount) revert InsufficientBalance();
        debtToken.safeTransferFrom(from, address(this), amount);
    }

    /**
     * @notice Get minimum collateralization ratio
     * @return The minimum collateralization ratio
     */
    function getMinimumCollateralization() external view returns (uint256) {
        return alchemist.minimumCollateralization();
    }

    /**
     * @notice Get total debt in the system
     * @return The total debt
     */
    function getTotalDebt() external view returns (uint256) {
        return alchemist.totalDebt();
    }

    /**
     * @notice Get deposit cap
     * @return The deposit cap
     */
    function getDepositCap() external view returns (uint256) {
        return alchemist.depositCap();
    }
} 