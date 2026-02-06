// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3.sol";
import "../alchemix-v3/src/interfaces/IAlchemistV3Position.sol";

/**
 * @title DirectV3Leverager
 * @dev Example of a leverager that works directly with Alchemist V3 without an adapter layer
 */
contract DirectV3Leverager is Ownable {
    IAlchemistV3 public alchemistV3;
    IAlchemistV3Position public positionNFT;
    
    address public yieldToken;
    address public underlyingToken;
    address public debtToken;
    
    // Mapping from user address to their position token ID
    mapping(address => uint256) public userPositions;
    
    uint256 constant FIXED_POINT_SCALAR = 1e18;
    
    constructor(
        address _alchemistV3,
        address _yieldToken,
        address _underlyingToken
    ) Ownable(msg.sender) {
        alchemistV3 = IAlchemistV3(_alchemistV3);
        positionNFT = IAlchemistV3Position(alchemistV3.alchemistPositionNFT());
        yieldToken = _yieldToken;
        underlyingToken = _underlyingToken;
        debtToken = alchemistV3.debtToken();
    }
    
    /**
     * @notice Get or create a position for the user
     * @param user The user address
     * @return tokenId The position token ID
     */
    function getOrCreatePosition(address user) public returns (uint256 tokenId) {
        tokenId = userPositions[user];
        if (tokenId == 0) {
            tokenId = positionNFT.mint(user);
            userPositions[user] = tokenId;
        }
    }
    
    /**
     * @notice Get the deposited balance for a user
     * @param user The user address
     * @return amount The deposited amount
     */
    function getDepositedBalance(address user) public view returns (uint256 amount) {
        uint256 tokenId = userPositions[user];
        if (tokenId == 0) return 0;
        
        (uint256 collateral, , ) = alchemistV3.getCDP(tokenId);
        return collateral;
    }
    
    /**
     * @notice Get the debt balance for a user
     * @param user The user address
     * @return amount The debt amount (positive = debt, negative = credit)
     */
    function getDebtBalance(address user) public view returns (int256 amount) {
        uint256 tokenId = userPositions[user];
        if (tokenId == 0) return 0;
        
        (, uint256 debt, ) = alchemistV3.getCDP(tokenId);
        return int256(debt);
    }
    
    /**
     * @notice Get the redeemable balance for a user
     * @param user The user address
     * @return amount The redeemable amount
     */
    function getRedeemableBalance(address user) public view returns (uint256 amount) {
        uint256 depositBalance = getDepositedBalance(user);
        int256 debtBalance = getDebtBalance(user);
        
        if (debtBalance <= 0) {
            return depositBalance + uint256(-debtBalance);
        } else {
            uint256 debtInUnderlying = alchemistV3.normalizeDebtTokensToUnderlying(uint256(debtBalance));
            return depositBalance > debtInUnderlying ? depositBalance - debtInUnderlying : 0;
        }
    }
    
    /**
     * @notice Get the borrow capacity for a user
     * @param user The user address
     * @return amount The borrowable amount
     */
    function getBorrowCapacity(address user) public view returns (uint256 amount) {
        uint256 minimumCollateralization = alchemistV3.minimumCollateralization();
        uint256 depositBalance = getDepositedBalance(user);
        int256 debtBalance = getDebtBalance(user);
        
        if (debtBalance < 0) {
            // User has credit, so they can borrow more
            uint256 creditInUnderlying = alchemistV3.normalizeDebtTokensToUnderlying(uint256(-debtBalance));
            uint256 adjustedBalance = depositBalance + (creditInUnderlying * minimumCollateralization / FIXED_POINT_SCALAR);
            return adjustedBalance * FIXED_POINT_SCALAR / minimumCollateralization;
        } else {
            // User has debt, calculate remaining capacity
            uint256 debtInUnderlying = alchemistV3.normalizeDebtTokensToUnderlying(uint256(debtBalance));
            uint256 debtAdjusted = debtInUnderlying * minimumCollateralization / FIXED_POINT_SCALAR;
            
            if (depositBalance > debtAdjusted) {
                uint256 adjustedBalance = depositBalance - debtAdjusted;
                return adjustedBalance * FIXED_POINT_SCALAR / minimumCollateralization;
            } else {
                return 0;
            }
        }
    }
    
    /**
     * @notice Deposit underlying tokens
     * @param amount The amount to deposit
     * @param minAmountOut The minimum amount of shares to receive
     * @return shares The amount of shares received
     */
    function depositUnderlying(uint256 amount, uint256 minAmountOut) external returns (uint256 shares) {
        // Transfer tokens from user
        IERC20(yieldToken).transferFrom(msg.sender, address(this), amount);
        
        // Approve to alchemist
        IERC20(yieldToken).approve(address(alchemistV3), amount);
        
        // Get or create position
        uint256 tokenId = getOrCreatePosition(msg.sender);
        
        // Deposit
        shares = alchemistV3.deposit(amount, msg.sender, tokenId);
        require(shares >= minAmountOut, "Insufficient shares received");
    }
    
    /**
     * @notice Mint debt tokens
     * @param amount The amount to mint
     * @param recipient The recipient of the tokens
     */
    function mint(uint256 amount, address recipient) external {
        uint256 tokenId = userPositions[msg.sender];
        require(tokenId > 0, "No position found");
        
        alchemistV3.mint(tokenId, amount, recipient);
    }
    
    /**
     * @notice Burn debt tokens
     * @param amount The amount to burn
     */
    function burn(uint256 amount) external {
        uint256 tokenId = userPositions[msg.sender];
        require(tokenId > 0, "No position found");
        
        // Transfer debt tokens from user
        IERC20(debtToken).transferFrom(msg.sender, address(this), amount);
        
        // Approve to alchemist
        IERC20(debtToken).approve(address(alchemistV3), amount);
        
        // Burn
        alchemistV3.burn(amount, tokenId);
    }
    
    /**
     * @notice Withdraw underlying tokens
     * @param shares The amount of shares to withdraw
     * @param recipient The recipient of the tokens
     * @param minAmountOut The minimum amount of underlying to receive
     * @return amount The amount of underlying tokens withdrawn
     */
    function withdrawUnderlying(uint256 shares, address recipient, uint256 minAmountOut) external returns (uint256 amount) {
        uint256 tokenId = userPositions[msg.sender];
        require(tokenId > 0, "No position found");
        
        amount = alchemistV3.withdraw(shares, recipient, tokenId);
        require(amount >= minAmountOut, "Insufficient underlying received");
    }
    
    /**
     * @notice Approve mint allowance
     * @param spender The spender address
     * @param amount The amount to approve
     */
    function approveMint(address spender, uint256 amount) external {
        uint256 tokenId = getOrCreatePosition(msg.sender);
        alchemistV3.approveMint(tokenId, spender, amount);
    }
} 